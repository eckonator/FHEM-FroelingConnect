################################################################################
# $Id: 73_FroelingConnect.pm 00001 2026-05-01 00:00:00Z markus $
#
# FHEM module for Fröling Connect Cloud API
# Fetches boiler/heating data directly from connect-api.froeling.com
#
# Based on API analysis of MMM-FroelingConnect (MagicMirror module)
# by Markus Eckert https://github.com/eckonator/
#
# Credential encryption pattern based on 98_vitoconnect.pm / FRITZBOX module
#
# This file is part of fhem.
# Fhem is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
################################################################################

package main;

use strict;
use warnings;
use utf8;
use HttpUtils;
use JSON;
use Encode qw(encode decode);
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);

my $FC_VERSION    = "1.1.0";
my $FC_USER_AGENT = "Froeling PROD/2107.1 (com.froeling.connect-ios; build:2107.1.01; iOS 14.8.0) Alamofire/4.8.1";
my $FC_API_BASE   = "https://connect-api.froeling.com";
my $FC_FCS_BASE   = "https://connect-api.froeling.com/fcs/v1.0/resources/user";
my $FC_TOKEN_TTL  = 11.5 * 3600;   # Re-login after 11.5 hours

################################################################################
# Initialize – register all FHEM callback functions
################################################################################
sub FroelingConnect_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}    = \&FroelingConnect_Define;
    $hash->{UndefFn}  = \&FroelingConnect_Undef;
    $hash->{DeleteFn} = \&FroelingConnect_Delete;
    $hash->{SetFn}    = \&FroelingConnect_Set;
    $hash->{GetFn}    = \&FroelingConnect_Get;
    $hash->{AttrFn}   = \&FroelingConnect_Attr;
    $hash->{AttrList} =
        "interval " .
        "facilityIndex " .
        "allowSet:0,1 " .
        "disable:1,0 " .
        "disabledForIntervals " .
        $readingFnAttributes;

    return;
}

################################################################################
# Define – called on 'define <name> FroelingConnect <username>'
################################################################################
sub FroelingConnect_Define {
    my ($hash, $def) = @_;
    my @a = split(/\s+/, $def);

    return "Usage: define <name> FroelingConnect <username (E-Mail)>"
        if @a < 3;

    my $name     = $a[0];
    my $username = $a[2];

    $hash->{USERNAME}         = $username;
    $hash->{VERSION}          = $FC_VERSION;
    $hash->{".access_token"}  = "";
    $hash->{".userId"}        = "";
    $hash->{".facilityId"}    = "";
    $hash->{".components"}    = [];
    $hash->{".setParams"}     = {};
    $hash->{".cfgPrefix"}     = {};
    $hash->{".refreshQueue"}  = {};
    $hash->{NOTIFYDEV}        = "global";

    RemoveInternalTimer($hash);

    my $pw = FroelingConnect_ReadKeyValue($hash, "password");
    if (!defined($pw) || $pw eq "") {
        readingsSingleUpdate($hash, "state",
            "Passwort setzen: set $name password <Passwort>", 1);
        return;
    }

    readingsSingleUpdate($hash, "state", "initializing", 1);
    InternalTimer(gettimeofday() + 2, \&FroelingConnect_Login, $hash);

    return;
}

################################################################################
# Undef – called when device is deleted or redefined
################################################################################
sub FroelingConnect_Undef {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    return;
}

################################################################################
# Delete – called on permanent deletion; removes stored password
################################################################################
sub FroelingConnect_Delete {
    my ($hash, $name) = @_;
    FroelingConnect_DeleteKeyValue($hash, "password");
    return;
}

################################################################################
# Set
################################################################################
sub FroelingConnect_Set {
    my ($hash, $name, $cmd, @args) = @_;

    my $setParams = $hash->{".setParams"} // {};
    my $setlist   = "password update:noArg relogin:noArg";

    # The writing commands are only offered while allowSet is enabled - calling
    # them anyway (e.g. from a DOIF) still answers with an explanatory error.
    if (AttrVal($name, "allowSet", 0)) {
        $setlist .= " parameter";
        for my $p (sort keys %$setParams) {
            $setlist .= " " . $p . FroelingConnect_SetWidget($setParams->{$p});
        }
    }

    if ($cmd eq "password") {
        return "Usage: set $name password <Passwort>" unless @args;
        my $err = FroelingConnect_StoreKeyValue($hash, "password", $args[0]);
        return $err if $err;
        Log3($name, 3, "FroelingConnect ($name) - password stored");
        RemoveInternalTimer($hash);
        $hash->{".access_token"} = "";
        $hash->{".userId"}       = "";
        $hash->{".facilityId"}   = "";
        $hash->{".components"}   = [];
        InternalTimer(gettimeofday() + 1, \&FroelingConnect_Login, $hash);
        return;
    }

    if ($cmd eq "update") {
        RemoveInternalTimer($hash, \&FroelingConnect_StartUpdate);
        FroelingConnect_StartUpdate($hash);
        return;
    }

    if ($cmd eq "relogin") {
        RemoveInternalTimer($hash);
        $hash->{".access_token"} = "";
        $hash->{".userId"}       = "";
        $hash->{".facilityId"}   = "";
        $hash->{".components"}   = [];
        InternalTimer(gettimeofday() + 1, \&FroelingConnect_Login, $hash);
        return;
    }

    # Expert command: write any parameter id directly, without validation
    if ($cmd eq "parameter") {
        return "Usage: set $name parameter <parameterId> <value>" if @args < 2;
        my $err = FroelingConnect_SetAllowed($hash);
        return $err if defined $err;
        my $paramId = shift @args;
        FroelingConnect_SetParameter($hash, $paramId, join(" ", @args), undef,
                                     "parameter $paramId");
        return;
    }

    # Dynamically discovered, editable parameters
    if (exists $setParams->{$cmd}) {
        return "Usage: set $name $cmd <value>" unless @args;
        my $err = FroelingConnect_SetAllowed($hash);
        return $err if defined $err;

        my $p = $setParams->{$cmd};
        my ($raw, $verr) = FroelingConnect_ValidateValue($p, join(" ", @args));
        return "$cmd: $verr" if defined $verr;

        FroelingConnect_SetParameter($hash, $p->{id}, $raw, $p->{componentId}, $cmd);
        return;
    }

    return "Unknown argument $cmd, choose one of $setlist";
}

################################################################################
# Get
################################################################################
sub FroelingConnect_Get {
    my ($hash, $name, $cmd, @args) = @_;

    my $getlist = "update:noArg";

    if ($cmd eq "update") {
        FroelingConnect_StartUpdate($hash);
        return;
    }

    return "Unknown argument $cmd, choose one of $getlist";
}

################################################################################
# Attr
################################################################################
sub FroelingConnect_Attr {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};

    if ($attrName eq "disable") {
        if ($cmd eq "set" && $attrVal == 1) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate($hash, "state", "disabled", 1);
        } elsif ($cmd eq "del" || ($cmd eq "set" && $attrVal == 0)) {
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday() + 2, \&FroelingConnect_Login, $hash);
        }
    }

    if ($attrName eq "interval" && $cmd eq "set") {
        return "interval must be a number >= 1" unless ($attrVal =~ /^\d+$/ && $attrVal >= 1);
    }

    return;
}

################################################################################
# API Step 1: Login
# POST https://connect-api.froeling.com/app/v1.0/resources/loginNew
################################################################################
sub FroelingConnect_Login {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if (IsDisabled($name)) {
        Log3($name, 4, "FroelingConnect ($name) - disabled, skip login");
        return;
    }

    my $username = $hash->{USERNAME};
    my $password = FroelingConnect_ReadKeyValue($hash, "password");

    if (!defined($password) || $password eq "") {
        readingsSingleUpdate($hash, "state",
            "Passwort setzen: set $name password <Passwort>", 1);
        return;
    }

    Log3($name, 4, "FroelingConnect ($name) - login as $username");

    my $body = encode_json({
        osType   => "IOS",
        userName => $username,
        password => $password,
    });

    my $param = {
        url      => "$FC_API_BASE/app/v1.0/resources/loginNew",
        method   => "POST",
        header   => "Content-Type: application/json\r\n" .
                    "Accept: */*\r\n" .
                    "User-Agent: $FC_USER_AGENT\r\n" .
                    "Accept-Language: de\r\n" .
                    "Connection: keep-alive",
        data     => $body,
        hash     => $hash,
        sslargs  => { SSL_verify_mode => 0 },
        timeout  => 30,
        callback => \&FroelingConnect_LoginCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_LoginCallback {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        Log3($name, 2, "FroelingConnect ($name) - login network error: $err");
        readingsSingleUpdate($hash, "state", "login error: $err", 1);
        my $retry = AttrVal($name, "interval", 5) * 60;
        InternalTimer(gettimeofday() + $retry, \&FroelingConnect_Login, $hash);
        return;
    }

    my $code = $param->{code} // 0;
    $hash->{API_LAST_MSG} = $code;

    if ($code != 200) {
        Log3($name, 2, "FroelingConnect ($name) - login HTTP $code");
        readingsSingleUpdate($hash, "state", "login error: HTTP $code", 1);
        my $retry = AttrVal($name, "interval", 5) * 60;
        InternalTimer(gettimeofday() + $retry, \&FroelingConnect_Login, $hash);
        return;
    }

    # Extract Authorization token from response headers
    my $token = "";
    my $httpheader = $param->{httpheader} // "";
    if ($httpheader =~ /\bAuthorization:\s*(\S+(?:\s+\S+)?)/i) {
        $token = $1;
    }

    if (!$token) {
        Log3($name, 2, "FroelingConnect ($name) - login: no Authorization header in response");
        readingsSingleUpdate($hash, "state", "login error: no token received", 1);
        return;
    }

    my $json = eval { decode_json($data) };
    if ($@) {
        Log3($name, 2, "FroelingConnect ($name) - login JSON error: $@");
        readingsSingleUpdate($hash, "state", "login error: JSON parse failed", 1);
        return;
    }

    my $userId = $json->{userId} // $json->{id} // "";
    $hash->{".access_token"} = $token;
    $hash->{".userId"}       = $userId;

    Log3($name, 4, "FroelingConnect ($name) - login OK, userId=$userId");

    # Schedule token refresh before expiry
    RemoveInternalTimer($hash, \&FroelingConnect_Login);
    InternalTimer(gettimeofday() + $FC_TOKEN_TTL, \&FroelingConnect_Login, $hash);

    if ($hash->{".facilityId"} && scalar(@{$hash->{".components"}}) > 0) {
        # Token refresh only – update chain is already running via its own timer
        Log3($name, 4, "FroelingConnect ($name) - token refreshed, update chain continues");
        readingsSingleUpdate($hash, "state", "token refreshed", 1);
    } else {
        # First login – start full discovery
        FroelingConnect_GetFacilities($hash);
    }

    return;
}

################################################################################
# API Step 2: Get Facilities
# GET https://connect-api.froeling.com/app/v1.0/resources/user/getFacilities
################################################################################
sub FroelingConnect_GetFacilities {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $param = {
        url      => "$FC_API_BASE/app/v1.0/resources/user/getFacilities",
        method   => "GET",
        header   => "Accept: */*\r\n" .
                    "User-Agent: $FC_USER_AGENT\r\n" .
                    "Accept-Language: de\r\n" .
                    "Authorization: " . $hash->{".access_token"},
        hash     => $hash,
        sslargs  => { SSL_verify_mode => 0 },
        timeout  => 30,
        callback => \&FroelingConnect_GetFacilitiesCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_GetFacilitiesCallback {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err || ($param->{code} // 0) != 200) {
        my $msg = $err || "HTTP " . ($param->{code} // 0);
        Log3($name, 2, "FroelingConnect ($name) - getFacilities error: $msg");
        readingsSingleUpdate($hash, "state", "error: getFacilities: $msg", 1);
        return;
    }

    my $json = eval { decode_json($data) };
    if ($@ || ref($json) ne 'ARRAY' || !@$json) {
        Log3($name, 2, "FroelingConnect ($name) - getFacilities: empty or invalid response");
        readingsSingleUpdate($hash, "state", "error: no facilities found", 1);
        return;
    }

    my $idx      = AttrVal($name, "facilityIndex", 0);
    my $facility = $json->[$idx];

    if (!$facility) {
        Log3($name, 2, "FroelingConnect ($name) - facility index $idx not found (only " .
            scalar(@$json) . " facilities)");
        readingsSingleUpdate($hash, "state", "error: facilityIndex $idx not found", 1);
        return;
    }

    $hash->{".facilityId"} = $facility->{id};
    $hash->{FACILITY_ID}   = $facility->{id};
    $hash->{FACILITY_NAME} = $facility->{name} // "";

    Log3($name, 4, "FroelingConnect ($name) - facility: '$hash->{FACILITY_NAME}' " .
        "(ID: $hash->{FACILITY_ID})");

    FroelingConnect_GetComponentList($hash);
    return;
}

################################################################################
# API Step 3: Get Component List
# GET .../fcs/v1.0/resources/user/{userId}/facility/{facilityId}/componentList
################################################################################
sub FroelingConnect_GetComponentList {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $userId = $hash->{".userId"};
    my $facId  = $hash->{".facilityId"};

    my $param = {
        url      => "$FC_FCS_BASE/$userId/facility/$facId/componentList",
        method   => "GET",
        header   => "Accept: */*\r\n" .
                    "User-Agent: $FC_USER_AGENT\r\n" .
                    "Accept-Language: de\r\n" .
                    "Authorization: " . $hash->{".access_token"},
        hash     => $hash,
        sslargs  => { SSL_verify_mode => 0 },
        timeout  => 30,
        callback => \&FroelingConnect_GetComponentListCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_GetComponentListCallback {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err || ($param->{code} // 0) != 200) {
        my $msg = $err || "HTTP " . ($param->{code} // 0);
        Log3($name, 2, "FroelingConnect ($name) - getComponentList error: $msg");
        readingsSingleUpdate($hash, "state", "error: getComponentList: $msg", 1);
        return;
    }

    my $json = eval { decode_json($data) };
    if ($@ || ref($json) ne 'ARRAY' || !@$json) {
        Log3($name, 2, "FroelingConnect ($name) - getComponentList: empty or invalid response");
        readingsSingleUpdate($hash, "state", "error: no components found", 1);
        return;
    }

    # Deduplicate components by componentId (same logic as MagicMirror node_helper)
    my @components;
    my %seen;
    for my $comp (@$json) {
        my $id  = $comp->{componentId} // next;
        next if $seen{$id}++;
        push @components, {
            id              => $id,
            displayName     => $comp->{displayName}     // "",
            displayCategory => $comp->{displayCategory} // "",
        };
    }

    $hash->{".components"} = \@components;
    Log3($name, 4, "FroelingConnect ($name) - " . scalar(@components) . " components found");

    FroelingConnect_StartUpdate($hash);
    return;
}

################################################################################
# API Step 4: Periodic data update (one component per HTTP call)
################################################################################
sub FroelingConnect_StartUpdate {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if (IsDisabled($name)) {
        Log3($name, 4, "FroelingConnect ($name) - disabled, skip update");
        return;
    }

    if (!$hash->{".facilityId"} || !scalar(@{$hash->{".components"}})) {
        Log3($name, 3, "FroelingConnect ($name) - no facility/components, triggering re-login");
        FroelingConnect_Login($hash);
        return;
    }

    Log3($name, 4, "FroelingConnect ($name) - starting data update");
    $hash->{".updateIdx"}  = 0;
    $hash->{".newReadings"} = {};

    FroelingConnect_FetchNextComponent($hash);
    return;
}

sub FroelingConnect_FetchNextComponent {
    my ($hash) = @_;
    my $name  = $hash->{NAME};
    my $idx   = $hash->{".updateIdx"};
    my @comps = @{$hash->{".components"}};

    if ($idx >= scalar(@comps)) {
        FroelingConnect_UpdateDone($hash);
        return;
    }

    my $comp   = $comps[$idx];
    my $userId = $hash->{".userId"};
    my $facId  = $hash->{".facilityId"};
    my $compId = $comp->{id};

    Log3($name, 5, "FroelingConnect ($name) - fetching component [$idx] " .
        "$compId: $comp->{displayName}");

    my $param = {
        url      => "$FC_FCS_BASE/$userId/facility/$facId/component/$compId",
        method   => "GET",
        header   => "Accept: */*\r\n" .
                    "User-Agent: $FC_USER_AGENT\r\n" .
                    "Accept-Language: de\r\n" .
                    "Authorization: " . $hash->{".access_token"},
        hash     => $hash,
        sslargs  => { SSL_verify_mode => 0 },
        timeout  => 30,
        callback => \&FroelingConnect_FetchComponentCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_FetchComponentCallback {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $idx  = $hash->{".updateIdx"};
    my $code = $param->{code} // 0;

    if ($code == 401) {
        Log3($name, 3, "FroelingConnect ($name) - 401 Unauthorized at component [$idx], " .
            "token expired – triggering re-login");
        RemoveInternalTimer($hash, \&FroelingConnect_Login);
        $hash->{".access_token"} = "";
        InternalTimer(gettimeofday() + 2, \&FroelingConnect_Login, $hash);
        return;
    }

    if ($err || $code != 200) {
        my $msg = $err || "HTTP $code";
        Log3($name, 2, "FroelingConnect ($name) - component [$idx] error: $msg – skipping");
        $hash->{".updateIdx"}++;
        FroelingConnect_FetchNextComponent($hash);
        return;
    }

    my $json = eval { decode_json($data) };
    if ($@) {
        Log3($name, 2, "FroelingConnect ($name) - component [$idx] JSON error: $@ – skipping");
        $hash->{".updateIdx"}++;
        FroelingConnect_FetchNextComponent($hash);
        return;
    }

    FroelingConnect_ParseComponent($hash, $json, $hash->{".newReadings"});

    $hash->{".updateIdx"}++;
    FroelingConnect_FetchNextComponent($hash);
    return;
}

################################################################################
# Parse one component response into readings (hashref $r) and refresh the list
# of settable parameters. Used by the periodic update and by the post-set
# refresh of a single component.
################################################################################
sub FroelingConnect_ParseComponent {
    my ($hash, $json, $r) = @_;
    my $name = $hash->{NAME};

    # Derive readings prefix from component's displayName
    my $displayName = $json->{displayName} // "";
    my $prefix      = FroelingConnect_DisplayNameToPrefix($displayName);
    Log3($name, 5, "FroelingConnect ($name) - component '$displayName' → prefix '$prefix'");

    my $stateView = $json->{stateView} // [];
    my $i = 0;

    for my $entry (@$stateView) {
        $r->{"$prefix.$i.displayName"}   = encode('UTF-8', $entry->{displayName}   // "");
        $r->{"$prefix.$i.value"}         = encode('UTF-8', $entry->{value}         // "");
        $r->{"$prefix.$i.unit"}          = encode('UTF-8', $entry->{unit}          // "");
        $r->{"$prefix.$i.name"}          = encode('UTF-8', $entry->{name}          // "");
        $r->{"$prefix.$i.parameterType"} = encode('UTF-8', $entry->{parameterType} // "");
        $r->{"$prefix.$i.editable"}      = $entry->{editable}      // 0;
        $r->{"$prefix.$i.id"}            = $entry->{id}            // "";
        $r->{"$prefix.$i.maxVal"}        = $entry->{maxVal}        // "";
        $r->{"$prefix.$i.minVal"}        = $entry->{minVal}        // "";

        if (defined $entry->{notificationConfigurable}) {
            $r->{"$prefix.$i.notificationConfigurable"} =
                $entry->{notificationConfigurable};
        }

        # The API delivers stringListKeyValues as an object (key → text); older
        # firmware versions were reported to send a plain list. Handle both.
        my $slkv = $entry->{stringListKeyValues};
        if (ref($slkv) eq 'HASH') {
            for my $k (FroelingConnect_SortKeys($slkv)) {
                $r->{"$prefix.$i.stringListKeyValues.$k"} =
                    encode('UTF-8', $slkv->{$k} // "");
            }
        } elsif (ref($slkv) eq 'ARRAY') {
            my $ki = 0;
            for my $kv (@$slkv) {
                $r->{"$prefix.$i.stringListKeyValues.$ki"} = $kv;
                $ki++;
            }
        }

        $i++;
    }

    FroelingConnect_CollectSetParams($hash, $json, $prefix, $r);
    return;
}

################################################################################
# Collect all editable parameters of a component into $hash->{".setParams"}
# and write them to readings below "{prefix}.cfg.".
#
# Editable parameters live in setupView and topView->configParams; the other
# sections are scanned as well so nothing settable is missed.
################################################################################
sub FroelingConnect_CollectSetParams {
    my ($hash, $json, $prefix, $r) = @_;
    my $name   = $hash->{NAME};
    my $compId = $json->{componentId} // "";

    return if $compId eq "";

    # Keep the cfg namespace collision-free even if two components share a
    # displayName (the index readings above keep their historic behaviour).
    my $claimed = $hash->{".cfgPrefix"} //= {};
    for my $other (keys %$claimed) {
        next if $other eq $compId;
        next unless ($claimed->{$other} // "") eq $prefix;
        my $num = $json->{componentNumber};
        $num = $compId if (!defined($num) || $num eq "");
        $prefix = FroelingConnect_DisplayNameToPrefix("$prefix$num");
        last;
    }
    $claimed->{$compId} = $prefix;

    my $setParams = $hash->{".setParams"} //= {};

    # Forget what we knew about this component - the plant config may have changed
    for my $k (keys %$setParams) {
        delete $setParams->{$k}
            if ($setParams->{$k}{componentId} // "") eq $compId;
    }

    # Ordered so that the "real" config sections win the name of a parameter
    my @entries;
    my $topView = $json->{topView};
    if (ref($topView) eq 'HASH') {
        for my $sect (qw(configParams infoParams pictureParams)) {
            my $sv = $topView->{$sect};
            push @entries, values %$sv if ref($sv) eq 'HASH';
            push @entries, @$sv        if ref($sv) eq 'ARRAY';
        }
    }
    for my $sect (qw(setupView stateView)) {
        my $sv = $json->{$sect};
        push @entries, @$sv        if ref($sv) eq 'ARRAY';
        push @entries, values %$sv if ref($sv) eq 'HASH';
    }

    my %seenId;
    for my $entry (@entries) {
        next unless ref($entry) eq 'HASH';
        next unless $entry->{editable};

        my $pName = $entry->{name} // "";
        my $pId   = $entry->{id}   // "";
        next if $pName eq "" || $pId eq "";
        next if $seenId{$pId}++;

        my $setName = "$prefix.cfg.$pName";
        if (exists $setParams->{$setName}) {
            # Same parameter name twice within one component - disambiguate by id
            $setName .= "_" . FroelingConnect_DisplayNameToPrefix($pId);
            next if exists $setParams->{$setName};
        }

        # Value list: object (key → text) or plain list. Store as UTF-8 bytes,
        # because that is what both the set list and the readings need.
        my $list;
        my $slkv = $entry->{stringListKeyValues};
        if (ref($slkv) eq 'HASH') {
            $list = {};
            $list->{$_} = encode('UTF-8', $slkv->{$_} // "") for keys %$slkv;
        } elsif (ref($slkv) eq 'ARRAY') {
            $list = {};
            my $ki = 0;
            for my $kv (@$slkv) {
                $list->{$ki} = encode('UTF-8', $kv // "");
                $ki++;
            }
        }

        my $unit = encode('UTF-8', $entry->{unit} // "");

        $setParams->{$setName} = {
            id          => $pId,
            componentId => $compId,
            name        => $pName,
            displayName => encode('UTF-8', $entry->{displayName} // ""),
            type        => $entry->{parameterType} // "",
            unit        => $unit,
            min         => $entry->{minVal},
            max         => $entry->{maxVal},
            list        => $list,
        };

        my $raw  = $entry->{value} // "";
        my $disp = (ref($list) eq 'HASH' && defined($list->{"$raw"}))
                 ? $list->{"$raw"}
                 : encode('UTF-8', "$raw");

        $r->{$setName}                 = $disp;
        $r->{"$setName.raw"}           = "$raw";
        $r->{"$setName.id"}            = $pId;
        $r->{"$setName.displayName"}   = $setParams->{$setName}{displayName};
        $r->{"$setName.parameterType"} = $setParams->{$setName}{type};
        $r->{"$setName.editable"}      = 1;
        $r->{"$setName.minVal"}        = $entry->{minVal} // "";
        $r->{"$setName.maxVal"}        = $entry->{maxVal} // "";
        $r->{"$setName.unit"}          = $unit if $unit ne "";

        if (ref($list) eq 'HASH') {
            $r->{"$setName.options"} =
                join(",", map { "$_=" . $list->{$_} } FroelingConnect_SortKeys($list));
        }
    }

    return;
}

sub FroelingConnect_UpdateDone {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $now  = int(gettimeofday());

    $hash->{API_LAST_MSG} = 200;
    $hash->{API_LAST_RES} = $now;
    $hash->{SOURCE}       = "$FC_API_BASE/ (200)";

    my $interval = AttrVal($name, "interval", 5);
    my $nextTime = $now + ($interval * 60);
    $hash->{NEXT} = FmtDateTime($nextTime);

    my $r = $hash->{".newReadings"};
    my $utcNow = strftime("%a, %d %b %Y %H:%M:%S GMT", gmtime($now));

    readingsBeginUpdate($hash);
    for my $key (sort keys %$r) {
        readingsBulkUpdate($hash, $key, $r->{$key});
    }
    readingsBulkUpdate($hash, "lastUpdate", $utcNow);
    readingsBulkUpdate($hash, "state", "active");
    readingsEndUpdate($hash, 1);

    my $count = scalar(keys %$r);
    Log3($name, 4, "FroelingConnect ($name) - update done, $count readings written, " .
        "next: " . $hash->{NEXT});

    RemoveInternalTimer($hash, \&FroelingConnect_StartUpdate);
    InternalTimer($nextTime, \&FroelingConnect_StartUpdate, $hash);

    return;
}

################################################################################
# API Step 5: Write a parameter
# PUT .../fcs/v1.0/resources/user/{userId}/facility/{facilityId}/parameter/{id}
# Body: {"value":"<value>"}
################################################################################
sub FroelingConnect_SetParameter {
    my ($hash, $paramId, $value, $compId, $label) = @_;
    my $name   = $hash->{NAME};
    my $userId = $hash->{".userId"};
    my $facId  = $hash->{".facilityId"};

    Log3($name, 3, "FroelingConnect ($name) - set $label: parameter $paramId = '$value'");

    my $param = {
        url         => "$FC_FCS_BASE/$userId/facility/$facId/parameter/$paramId",
        method      => "PUT",
        header      => "Content-Type: application/json\r\n" .
                       "Accept: */*\r\n" .
                       "User-Agent: $FC_USER_AGENT\r\n" .
                       "Accept-Language: de\r\n" .
                       "Authorization: " . $hash->{".access_token"},
        data        => encode_json({ value => "$value" }),
        hash        => $hash,
        sslargs     => { SSL_verify_mode => 0 },
        timeout     => 30,
        fcLabel     => $label,
        fcValue     => $value,
        fcComponent => $compId,
        callback    => \&FroelingConnect_SetParameterCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_SetParameterCallback {
    my ($param, $err, $data) = @_;
    my $hash  = $param->{hash};
    my $name  = $hash->{NAME};
    my $label = $param->{fcLabel} // "";
    my $code  = $param->{code}    // 0;
    my $result;

    if ($err) {
        Log3($name, 2, "FroelingConnect ($name) - set $label network error: $err");
        $result = "error: $err";
    }
    elsif ($code == 304) {
        # The API answers 304 when the parameter already had the requested value
        Log3($name, 4, "FroelingConnect ($name) - set $label: value unchanged (HTTP 304)");
        $result = "unchanged";
    }
    elsif ($code == 401) {
        Log3($name, 3, "FroelingConnect ($name) - set $label: 401 Unauthorized, " .
            "token expired – triggering re-login");
        $result = "error: HTTP 401 (token expired)";
        RemoveInternalTimer($hash, \&FroelingConnect_Login);
        $hash->{".access_token"} = "";
        InternalTimer(gettimeofday() + 2, \&FroelingConnect_Login, $hash);
    }
    elsif ($code < 200 || $code > 299) {
        my $msg = "HTTP $code";
        if (defined($data) && $data ne "") {
            my $body = $data;
            $body =~ s/\s+/ /g;
            $msg .= ": " . substr($body, 0, 200);
        }
        Log3($name, 2, "FroelingConnect ($name) - set $label failed: $msg");
        $result = "error: $msg";
    }
    else {
        Log3($name, 4, "FroelingConnect ($name) - set $label OK (HTTP $code)");
        $result = "ok";
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastSet",       "$label = " . ($param->{fcValue} // ""));
    readingsBulkUpdate($hash, "lastSetResult", $result);
    readingsEndUpdate($hash, 1);

    # Re-read the affected component so its readings show the new value
    if ($result eq "ok" && $param->{fcComponent}) {
        $hash->{".refreshQueue"}{$param->{fcComponent}} = 1;
        RemoveInternalTimer($hash, \&FroelingConnect_RefreshComponent);
        InternalTimer(gettimeofday() + 3, \&FroelingConnect_RefreshComponent, $hash);
    }

    return;
}

################################################################################
# Re-read a single component after a successful write
################################################################################
sub FroelingConnect_RefreshComponent {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $queue = $hash->{".refreshQueue"} //= {};
    my ($compId) = sort keys %$queue;
    return unless defined($compId) && $compId ne "";
    delete $queue->{$compId};

    if (!$hash->{".access_token"} || !$hash->{".facilityId"}) {
        Log3($name, 4, "FroelingConnect ($name) - refresh skipped, no session");
        return;
    }

    my $userId = $hash->{".userId"};
    my $facId  = $hash->{".facilityId"};

    Log3($name, 4, "FroelingConnect ($name) - re-reading component $compId after set");

    my $param = {
        url      => "$FC_FCS_BASE/$userId/facility/$facId/component/$compId",
        method   => "GET",
        header   => "Accept: */*\r\n" .
                    "User-Agent: $FC_USER_AGENT\r\n" .
                    "Accept-Language: de\r\n" .
                    "Authorization: " . $hash->{".access_token"},
        hash     => $hash,
        sslargs  => { SSL_verify_mode => 0 },
        timeout  => 30,
        callback => \&FroelingConnect_RefreshComponentCallback,
    };

    HttpUtils_NonblockingGet($param);
    return;
}

sub FroelingConnect_RefreshComponentCallback {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($err || $code != 200) {
        my $msg = $err || "HTTP $code";
        Log3($name, 3, "FroelingConnect ($name) - refresh after set failed: $msg");
    }
    else {
        my $json = eval { decode_json($data) };
        if ($@) {
            Log3($name, 3, "FroelingConnect ($name) - refresh after set: JSON error: $@");
        }
        else {
            my %r;
            FroelingConnect_ParseComponent($hash, $json, \%r);
            readingsBeginUpdate($hash);
            for my $key (sort keys %r) {
                readingsBulkUpdate($hash, $key, $r{$key});
            }
            readingsEndUpdate($hash, 1);
        }
    }

    if (scalar keys %{$hash->{".refreshQueue"} // {}}) {
        RemoveInternalTimer($hash, \&FroelingConnect_RefreshComponent);
        InternalTimer(gettimeofday() + 1, \&FroelingConnect_RefreshComponent, $hash);
    }

    return;
}

################################################################################
# Helper: is writing allowed / possible right now?
################################################################################
sub FroelingConnect_SetAllowed {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return "writing is disabled - set 'attr $name allowSet 1' to allow " .
           "this module to change values on the heating system"
        unless AttrVal($name, "allowSet", 0);

    return "not logged in yet - no access token available"
        unless $hash->{".access_token"};

    return "no facility known yet - wait for the first successful update"
        unless $hash->{".facilityId"};

    return undef;
}

################################################################################
# Helper: sort value list keys numerically when possible
################################################################################
sub FroelingConnect_SortKeys {
    my ($h) = @_;
    my @keys = keys %$h;
    return sort { $a <=> $b } @keys unless grep { !/^-?\d+$/ } @keys;
    return sort @keys;
}

################################################################################
# Helper: build the FHEMWEB widget hint for one settable parameter
################################################################################
sub FroelingConnect_SetWidget {
    my ($p) = @_;

    my $list = $p->{list};
    if (ref($list) eq 'HASH' && scalar(keys %$list)) {
        my @opts;
        for my $k (FroelingConnect_SortKeys($list)) {
            my $text = $list->{$k};
            # ',' and ':' would break the set list syntax - fall back to a textfield
            return "" if !defined($text) || $text eq "" || $text =~ /[,:]/;
            $text =~ s/\s+/_/g;
            push @opts, $text;
        }
        return @opts ? ":" . join(",", @opts) : "";
    }

    my ($min, $max) = ($p->{min}, $p->{max});
    if (defined($min) && defined($max)
        && $min =~ /^-?\d+$/ && $max =~ /^-?\d+$/
        && $max > $min && ($max - $min) <= 500) {
        return ":slider,$min,1,$max";
    }

    return "";
}

################################################################################
# Helper: validate a set value and translate it into the raw API value
# Returns ($rawValue, undef) on success or (undef, $errorMessage)
################################################################################
sub FroelingConnect_ValidateValue {
    my ($p, $value) = @_;

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return (undef, "no value given") if $value eq "";

    my $list = $p->{list};
    if (ref($list) eq 'HASH' && scalar(keys %$list)) {
        # Raw key given (e.g. '2')
        return ($value, undef) if exists $list->{$value};

        # Display text given, either as-is or with '_' instead of blanks
        my $plain = $value;
        $plain =~ s/_/ /g;
        for my $k (FroelingConnect_SortKeys($list)) {
            my $text = $list->{$k} // "";
            return ($k, undef) if lc($text) eq lc($value) || lc($text) eq lc($plain);
        }

        my @opts = map {
            my $t = $list->{$_} // ""; $t =~ s/\s+/_/g; "$_ ($t)"
        } FroelingConnect_SortKeys($list);
        return (undef, "invalid value '$value' - choose one of: " . join(", ", @opts));
    }

    $value =~ s/,/./;
    return (undef, "invalid value '$value' - a number is expected")
        unless $value =~ /^-?\d+(?:\.\d+)?$/;

    my ($min, $max) = ($p->{min}, $p->{max});
    if (defined($min) && defined($max)
        && $min =~ /^-?\d+(?:\.\d+)?$/ && $max =~ /^-?\d+(?:\.\d+)?$/
        && $max > $min
        && ($value < $min || $value > $max)) {
        my $unit = $p->{unit} // "";
        $unit = " $unit" if $unit ne "";
        return (undef, "value $value$unit is out of range ($min .. $max$unit)");
    }

    return ($value, undef);
}

################################################################################
# Helper: map component displayName to readings prefix
# "Puffer 01" → "puffer01", "Heizkreis 01" → "heizkreis01", "Kessel" → "kessel"
################################################################################
sub FroelingConnect_DisplayNameToPrefix {
    my ($displayName) = @_;
    my $p = lc($displayName);
    $p =~ s/ä/ae/g;
    $p =~ s/ö/oe/g;
    $p =~ s/ü/ue/g;
    $p =~ s/ß/ss/g;
    $p =~ s/\s+//g;
    $p =~ s/[^a-z0-9]//g;
    return $p;
}

################################################################################
# Credential storage – XOR obfuscation with FHEM's unique device ID
# Pattern copied from FRITZBOX / vitoconnect modules
################################################################################
sub FroelingConnect_StoreKeyValue {
    my ($hash, $kName, $value) = @_;
    my $index = $hash->{TYPE} . "_" . $hash->{NAME} . "_" . $kName;
    my $key   = getUniqueId() . $index;
    my $enc   = "";

    if (eval "use Digest::MD5;1") { ## no critic
        $key = Digest::MD5::md5_hex(unpack "H*", $key);
        $key .= Digest::MD5::md5_hex($key);
    }
    for my $char (split //, $value) {
        my $encode = chop($key);
        $enc .= sprintf("%.2x", ord($char) ^ ord($encode));
        $key = $encode . $key;
    }
    my $err = setKeyValue($index, $enc);
    return "error while saving the password: $err" if defined($err);
    return;
}

sub FroelingConnect_ReadKeyValue {
    my ($hash, $kName) = @_;
    my $name  = $hash->{NAME};
    my $index = $hash->{TYPE} . "_" . $hash->{NAME} . "_" . $kName;
    my $key   = getUniqueId() . $index;

    my ($err, $value) = getKeyValue($index);

    if (defined($err)) {
        Log3($name, 1, "FroelingConnect ($name) - ReadKeyValue error for '$kName': $err");
        return "";
    }

    return "" unless defined($value);

    if (eval "use Digest::MD5;1") { ## no critic
        $key = Digest::MD5::md5_hex(unpack "H*", $key);
        $key .= Digest::MD5::md5_hex($key);
    }
    my $dec = "";
    for my $char (map { pack('C', hex($_)) } ($value =~ /(..)/g)) {
        my $decode = chop($key);
        $dec .= chr(ord($char) ^ ord($decode));
        $key = $decode . $key;
    }
    return $dec;
}

sub FroelingConnect_DeleteKeyValue {
    my ($hash, $kName) = @_;
    my $index = $hash->{TYPE} . "_" . $hash->{NAME} . "_" . $kName;
    setKeyValue($index, undef);
    return;
}

1;

__END__

=pod

=item device
=item summary    FHEM module for Fröling Connect pellet/wood boiler cloud API
=item summary_DE FHEM-Modul für die Fröling Connect Cloud-API (Pellet-/Holzheizung)

=begin html

<a id="FroelingConnect"></a>
<h3>FroelingConnect</h3>
<ul>
  Directly fetches boiler and heating data from the Fröling Connect cloud API
  (connect-api.froeling.com). Replaces the previous setup of JsonMod + a local
  MagicMirror module acting as a JSON proxy server.
  <br><br>

  <b>Prerequisites</b><br>
  <ul>
    <li>A Fröling Connect account (same login as the Fröling mobile app)</li>
    <li>Perl modules: <code>JSON</code>, <code>HttpUtils</code> (FHEM internal)</li>
    <li>Network access to <code>connect-api.froeling.com</code> (port 443)</li>
  </ul>
  <br>

  <a id="FroelingConnect-define"></a>
  <b>Define</b><br>
  <ul>
    <code>define &lt;name&gt; FroelingConnect &lt;username&gt;</code>
    <br><br>
    Only the username (e-mail address) is provided in the define. The password is
    stored separately via <code>set &lt;name&gt; password</code> and is encrypted
    in FHEM's internal key store (never written to config files).
    <br><br>
    Example:<br>
    <code>define Froeling_PE1 FroelingConnect user@example.com</code><br>
    <code>set Froeling_PE1 password MySecretPassword</code>
  </ul>
  <br>

  <a id="FroelingConnect-set"></a>
  <b>Set</b><br>
  <ul>
    <li><code>password &lt;Passwort&gt;</code><br>
        Store the Fröling Connect password encrypted and trigger login.</li>
    <li><code>update</code><br>
        Immediately fetch current data from the API.</li>
    <li><code>relogin</code><br>
        Reset session and force a new login (useful after credential change).</li>
    <li><code>&lt;component&gt;.cfg.&lt;parameter&gt; &lt;value&gt;</code><br>
        Writes a value back to the heating system. One such command is offered for
        every parameter the API reports as editable; the command name is identical
        to the corresponding reading, e.g.<br>
        <code>set &lt;name&gt; kessel.cfg.boilerSetTemp 78</code><br>
        <code>set &lt;name&gt; kessel.cfg.mode2 Automatik</code><br>
        Numeric parameters are checked against <code>minVal</code>/<code>maxVal</code>
        before anything is sent. For parameters with a value list either the plain
        text (blanks may be written as <code>_</code>) or the raw key may be given.
        The commands only appear after the first successful update, and only while
        the attribute <code>allowSet</code> is set to 1.</li>
    <li><code>parameter &lt;parameterId&gt; &lt;value&gt;</code><br>
        Expert command: writes any parameter id directly, <b>without</b> range or
        value-list validation. Intended for parameters that are not offered as a
        command of their own. The id is the one shown in the <code>.id</code>
        readings, e.g. <code>set &lt;name&gt; parameter 7_28 78</code>.</li>
  </ul>
  <br>
  Writing requires the parameter "Fernschalten über connect möglich"
  (<code>remoteOn</code>) to be enabled on the boiler itself, otherwise the plant
  rejects any change. The result of a write is visible in the readings
  <code>lastSet</code> and <code>lastSetResult</code>; after a successful write the
  affected component is re-read a few seconds later.
  <br><br>

  <a id="FroelingConnect-get"></a>
  <b>Get</b><br>
  <ul>
    <li><code>update</code><br>
        Immediately fetch current data from the API.</li>
  </ul>
  <br>

  <a id="FroelingConnect-attr"></a>
  <b>Attributes</b><br>
  <ul>
    <li><code>interval &lt;minutes&gt;</code><br>
        Update interval in minutes. Default: 5.</li>
    <li><code>facilityIndex &lt;n&gt;</code><br>
        Zero-based index of the facility to use when multiple facilities are
        registered in the account. Default: 0.</li>
    <li><code>allowSet 1|0</code><br>
        Master switch for writing. As long as this is 0 (default) the module only
        reads: all parameter set commands are rejected and no write request is
        sent to the API. Set to 1 to allow this module to change values on your
        heating system.</li>
    <li><code>disable 1|0</code><br>
        Disables all polling when set to 1.</li>
    <li><code>disabledForIntervals HH:MM-HH:MM ...</code><br>
        Disable polling during specified time ranges.</li>
  </ul>
  <br>

  <a id="FroelingConnect-readings"></a>
  <b>Readings</b><br>
  <ul>
    Readings are grouped by component. The prefix is derived from the component's
    display name (lowercase, spaces and umlauts normalised), e.g.:
    <ul>
      <li><code>kessel.*</code> – Boiler/furnace (Kessel)</li>
      <li><code>austragung.*</code> – Pellet extraction (Austragung)</li>
      <li><code>puffer01.*</code> – Buffer tank (Puffer 01)</li>
      <li><code>boiler01.*</code> – DHW boiler (Boiler 01)</li>
      <li><code>heizkreis01.*</code> – Heating circuit (Heizkreis 01)</li>
    </ul>
    Each component parameter generates the following readings (N = index within
    component):<br>
    <code>{prefix}.N.displayName</code>, <code>.value</code>, <code>.unit</code>,
    <code>.name</code>, <code>.parameterType</code>, <code>.editable</code>,
    <code>.id</code>, <code>.maxVal</code>, <code>.minVal</code><br>
    Optionally: <code>.notificationConfigurable</code>,
    <code>.stringListKeyValues.K</code> (K = raw value, the reading holds the
    matching text, e.g. <code>0</code> = NEIN, <code>1</code> = JA)
    <br><br>
    In addition, every editable parameter of a component (from
    <code>setupView</code> and <code>topView.configParams</code>) is published
    below <code>{prefix}.cfg.</code> – these are exactly the parameters that can
    be written with the set commands of the same name:
    <ul>
      <li><code>{prefix}.cfg.{name}</code> – current value; for parameters with a
          value list the readable text instead of the raw number</li>
      <li><code>{prefix}.cfg.{name}.raw</code> – raw value as delivered by the API</li>
      <li><code>{prefix}.cfg.{name}.id</code> – parameter id used for writing</li>
      <li><code>{prefix}.cfg.{name}.displayName</code>,
          <code>.parameterType</code>, <code>.unit</code>,
          <code>.minVal</code>, <code>.maxVal</code>, <code>.editable</code></li>
      <li><code>{prefix}.cfg.{name}.options</code> – value list as
          <code>key=text,key=text</code>, only for selectable parameters</li>
    </ul>
    <code>lastSet</code> – last write attempt (command and value).<br>
    <code>lastSetResult</code> – <code>ok</code>, <code>unchanged</code> (the
    parameter already had that value) or <code>error: ...</code>.<br>
    <code>lastUpdate</code> – UTC timestamp of the last successful API poll.
  </ul>
</ul>

=end html

=begin html_DE

<a id="FroelingConnect"></a>
<h3>FroelingConnect</h3>
<ul>
  Holt Heizungs- und Kesseldaten direkt von der Fröling Connect Cloud-API
  (connect-api.froeling.com). Ersetzt das bisherige Setup aus JsonMod und einem
  lokalen MagicMirror-Modul als JSON-Proxy-Server.
  <br><br>

  <b>Voraussetzungen</b><br>
  <ul>
    <li>Ein Fröling Connect-Konto (gleicher Login wie die Fröling App)</li>
    <li>Perl-Module: <code>JSON</code>, <code>HttpUtils</code> (FHEM-intern)</li>
    <li>Netzwerkzugang zu <code>connect-api.froeling.com</code> (Port 443)</li>
  </ul>
  <br>

  <a id="FroelingConnect-define"></a>
  <b>Define</b><br>
  <ul>
    <code>define &lt;name&gt; FroelingConnect &lt;Benutzername&gt;</code>
    <br><br>
    Im define wird nur der Benutzername (E-Mail-Adresse) angegeben. Das Passwort
    wird separat über <code>set &lt;name&gt; password</code> gesetzt und
    verschlüsselt im internen FHEM-Schlüsselspeicher abgelegt (landet nie in
    Konfig-Dateien).
    <br><br>
    Beispiel:<br>
    <code>define Froeling_PE1 FroelingConnect user@example.com</code><br>
    <code>set Froeling_PE1 password MeinPasswort</code>
  </ul>
  <br>

  <a id="FroelingConnect-set"></a>
  <b>Set</b><br>
  <ul>
    <li><code>password &lt;Passwort&gt;</code><br>
        Passwort verschlüsselt speichern und Login starten.</li>
    <li><code>update</code><br>
        Sofortiger Datenabruf von der API.</li>
    <li><code>relogin</code><br>
        Session zurücksetzen und neuen Login erzwingen.</li>
    <li><code>&lt;Komponente&gt;.cfg.&lt;Parameter&gt; &lt;Wert&gt;</code><br>
        Schreibt einen Wert an die Heizung zurück. Für jeden Parameter, den die API
        als änderbar meldet, gibt es einen solchen Befehl; der Befehlsname ist
        identisch mit dem zugehörigen Reading, z.B.<br>
        <code>set &lt;name&gt; kessel.cfg.boilerSetTemp 78</code><br>
        <code>set &lt;name&gt; kessel.cfg.mode2 Automatik</code><br>
        Zahlenwerte werden vor dem Senden gegen <code>minVal</code>/<code>maxVal</code>
        geprüft. Bei Parametern mit Auswahlliste kann entweder der Klartext
        (Leerzeichen dürfen als <code>_</code> geschrieben werden) oder der
        numerische Schlüssel angegeben werden. Die Befehle erscheinen erst nach dem
        ersten erfolgreichen Update und nur solange das Attribut
        <code>allowSet</code> auf 1 steht.</li>
    <li><code>parameter &lt;parameterId&gt; &lt;Wert&gt;</code><br>
        Experten-Befehl: schreibt eine beliebige Parameter-ID direkt,
        <b>ohne</b> Prüfung von Wertebereich oder Auswahlliste. Gedacht für
        Parameter, für die es keinen eigenen Befehl gibt. Die ID steht in den
        <code>.id</code>-Readings, z.B. <code>set &lt;name&gt; parameter 7_28 78</code>.</li>
  </ul>
  <br>
  Voraussetzung fürs Schreiben ist, dass an der Anlage selbst der Parameter
  "Fernschalten über connect möglich" (<code>remoteOn</code>) aktiviert ist,
  sonst lehnt die Heizung jede Änderung ab. Das Ergebnis eines Schreibvorgangs
  steht in den Readings <code>lastSet</code> und <code>lastSetResult</code>; nach
  erfolgreichem Schreiben wird die betroffene Komponente wenige Sekunden später
  neu eingelesen.
  <br><br>

  <a id="FroelingConnect-attr"></a>
  <b>Attribute</b><br>
  <ul>
    <li><code>interval &lt;Minuten&gt;</code><br>
        Abfrage-Intervall in Minuten. Standard: 5.</li>
    <li><code>facilityIndex &lt;n&gt;</code><br>
        Nullbasierter Index der Anlage, wenn mehrere Anlagen im Konto vorhanden
        sind. Standard: 0.</li>
    <li><code>allowSet 1|0</code><br>
        Hauptschalter fürs Schreiben. Solange dieses Attribut 0 ist (Standard),
        liest das Modul ausschließlich: alle Parameter-set-Befehle werden
        abgewiesen und es geht kein Schreibzugriff an die API. Erst mit 1 darf das
        Modul Werte an der Heizung verändern.</li>
    <li><code>disable 1|0</code><br>
        Deaktiviert alle Abfragen wenn 1.</li>
    <li><code>disabledForIntervals HH:MM-HH:MM ...</code><br>
        Abfragen in den angegebenen Zeiträumen deaktivieren.</li>
  </ul>
  <br>

  <a id="FroelingConnect-readings"></a>
  <b>Readings</b><br>
  <ul>
    Die Readings sind nach Komponenten gruppiert, das Präfix wird aus dem
    Anzeigenamen abgeleitet (klein, ohne Leerzeichen/Umlaute), z.B.
    <code>kessel.*</code>, <code>puffer01.*</code>, <code>heizkreis01.*</code>.
    <br><br>
    Je Parameter aus <code>stateView</code> (N = Index innerhalb der Komponente):<br>
    <code>{präfix}.N.displayName</code>, <code>.value</code>, <code>.unit</code>,
    <code>.name</code>, <code>.parameterType</code>, <code>.editable</code>,
    <code>.id</code>, <code>.maxVal</code>, <code>.minVal</code>, optional
    <code>.notificationConfigurable</code> und
    <code>.stringListKeyValues.K</code> (K = Rohwert, das Reading enthält den
    zugehörigen Text, z.B. <code>0</code> = NEIN, <code>1</code> = JA).
    <br><br>
    Zusätzlich wird jeder änderbare Parameter einer Komponente (aus
    <code>setupView</code> und <code>topView.configParams</code>) unter
    <code>{präfix}.cfg.</code> veröffentlicht – genau diese Parameter lassen sich
    mit den gleichnamigen set-Befehlen schreiben:
    <ul>
      <li><code>{präfix}.cfg.{name}</code> – aktueller Wert; bei Parametern mit
          Auswahlliste der lesbare Text statt der Zahl</li>
      <li><code>{präfix}.cfg.{name}.raw</code> – Rohwert wie von der API geliefert</li>
      <li><code>{präfix}.cfg.{name}.id</code> – Parameter-ID, die beim Schreiben
          verwendet wird</li>
      <li><code>{präfix}.cfg.{name}.displayName</code>,
          <code>.parameterType</code>, <code>.unit</code>,
          <code>.minVal</code>, <code>.maxVal</code>, <code>.editable</code></li>
      <li><code>{präfix}.cfg.{name}.options</code> – Auswahlliste als
          <code>Schlüssel=Text,Schlüssel=Text</code>, nur bei Auswahlparametern</li>
    </ul>
    <code>lastSet</code> – letzter Schreibversuch (Befehl und Wert).<br>
    <code>lastSetResult</code> – <code>ok</code>, <code>unchanged</code> (der
    Parameter hatte den Wert bereits) oder <code>error: ...</code>.<br>
    <code>lastUpdate</code> – UTC-Zeitstempel der letzten erfolgreichen Abfrage.
  </ul>
</ul>

=end html_DE

=cut
