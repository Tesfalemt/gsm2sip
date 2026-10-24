#!/bin/bash
#
# Decide whether a phone can run the gateway with a fully digital audio path.
#
# Support is a property of the vendor image, not of the chip.  The Qualcomm
# audio HAL family carries this code almost universally, but whether the OEM
# built it in, and whether the audio policy exposes a route to the modem
# uplink, varies per device and per ROM.
#
# The audio-policy check needs no root, so a candidate phone can be vetted
# before rooting it.  The HAL and mixer checks need root (Magisk, with
# Superuser access set to "Apps and ADB").
#
# Usage:  tools/check-device.sh [adb-serial]

set -u
SERIAL="${1:-}"
ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

sh_()  { "${ADB[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }
su_()  { "${ADB[@]}" shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }
have_root() { [ "$(su_ 'id -u')" = "0" ]; }

pass=0; fail=0; unknown=0
ok()  { echo "  [ok]      $1"; pass=$((pass+1)); }
no()  { echo "  [MISSING] $1"; fail=$((fail+1)); }
unk() { echo "  [?]       $1"; unknown=$((unknown+1)); }

echo "=== Device ==="
echo "  model    : $(sh_ getprop ro.product.model)"
echo "  board    : $(sh_ getprop ro.board.platform)"
echo "  hardware : $(sh_ getprop ro.hardware)"
echo "  android  : $(sh_ getprop ro.build.version.release)"
echo "  vendor   : $(sh_ getprop ro.vendor.build.fingerprint)"
echo

if [ "$(sh_ getprop ro.hardware)" != "qcom" ]; then
    echo "Not a Qualcomm device — stop here."
    echo "Injection needs incall_music and capture needs the in-call record"
    echo "session; neither exists outside the Qualcomm audio HAL.  A Samsung"
    echo "Exynos S10e was checked and has no telephony route in its audio"
    echo "policy at all: three mixPorts (deep, fast, primary) and nothing else."
    exit 1
fi

if sh_ 'pm list features' | grep -q 'feature:android.hardware.telephony'; then
    ok "telephony hardware present"
else
    no "no telephony — this device cannot place GSM calls (WiFi-only?)"
fi

# ── 1. audio policy (no root needed) — the decisive one ──────────────
echo
echo "=== 1. Audio policy: is there a route to the modem uplink? ==="
# Ask audioserver which policy it actually loaded rather than guessing the
# file: the Galaxy A52 5G ships an audio_policy_configuration.xml with three
# mixPorts and no telephony device, yet loads audio_policy_configuration_base.xml,
# whose voice_tx mixPort is routed to Telephony Tx.  Reading the first file
# alone reported "nothing to inject into" on a phone that has the route.
#
# Any output mixPort that lists Telephony Tx among its devices is a way into
# the uplink — incall_music_uplink on the Poco X3 NFC, voice_tx on AOSP-style
# policies (Pixel, Samsung's Qualcomm phones).
TX_PORTS=$(sh_ 'dumpsys media.audio_policy' | awk '
    /^ *output [0-9]+:/            { inout = 1; next }
    /^ *input [0-9]+:/             { inout = 0; next }
    inout && /^ *- name: /         { sub(/^ *- name: /, ""); port = $0 }
    inout && /AUDIO_DEVICE_OUT_TELEPHONY_TX/ { print port }' | sort -u)
if [ -z "$TX_PORTS" ]; then
    # Older Android, or dumpsys not allowed: fall back to the XML files.
    for f in $(sh_ 'ls /odm/etc/audio_policy_configuration*.xml /vendor/etc/audio_policy_configuration*.xml 2>/dev/null'); do
        sh_ "grep -q 'sink=\"Telephony Tx\"' $f && echo y" | grep -q y || continue
        TX_PORTS=$(sh_ "grep -A1 'sink=\"Telephony Tx\"' $f" | grep -o 'sources="[^"]*"' | cut -d'"' -f2 | tr ',' '\n' | sort -u)
        [ -n "$TX_PORTS" ] && { echo "            (from $f — dumpsys gave nothing)"; break; }
    done
fi
if [ -n "$TX_PORTS" ]; then
    ok "output routed to Telephony Tx: $(echo $TX_PORTS)"
else
    no "no output routed to Telephony Tx — nothing to inject the agent into"
fi

# The HAL's own mixer paths for the two in-call usecases.  Which
# mixer_paths file the HAL picks depends on the sound card name (root to
# read), so this looks at the default one.  The front-end named here is the
# one a DeviceProfile has to drive.
MP=/vendor/etc/mixer_paths.xml
if sh_ "[ -r $MP ] && echo y" | grep -q y; then
    path_ctls() {  # $1 = mixer path name -> its ctl names, one per line
        sh_ "grep -A4 '<path name=\"$1\">' $MP" | sed '1d;/<\/path>/,$d' \
            | grep -o 'name="[^"]*"' | cut -d'"' -f2
    }
    IM=$(path_ctls incall_music_uplink)
    [ -n "$IM" ] \
        && ok "mixer path incall_music_uplink: $(echo "$IM" | paste -sd, -)" \
        || unk "no incall_music_uplink mixer path in $MP (the S4 Mini had none and still worked)"
    RD=$(path_ctls incall-rec-downlink)
    [ -n "$RD" ] \
        && ok "mixer path incall-rec-downlink: $(echo "$RD" | paste -sd, -)" \
        || unk "no incall-rec-downlink mixer path in $MP"
else
    unk "$MP not readable"
fi

# ── 2. HAL (root) ────────────────────────────────────────────────────
echo
echo "=== 2. Audio HAL ==="
if ! have_root; then
    unk "needs root — enable Magisk Superuser access = 'Apps and ADB', then"
    echo "            run 'adb shell su -c id' once and grant the prompt"
else
    HAL=$(su_ 'ls /vendor/lib64/hw/audio.primary.*.so /vendor/lib/hw/audio.primary.*.so 2>/dev/null' | grep -v default | head -1)
    if [ -z "$HAL" ]; then
        unk "no vendor audio HAL found"
    else
        echo "            $HAL"
        S=$(su_ "strings $HAL")
        echo "$S" | grep -q "AUDIO_OUTPUT_FLAG_INCALL_MUSIC" \
            && ok "incall_music output flag   — agent audio into the uplink" \
            || no "incall_music output flag   — no digital path to the caller"
        echo "$S" | grep -q "USECASE_INCALL_REC" \
            && ok "in-call record usecases    — caller into the agent" \
            || no "in-call record usecases    — capture would be acoustic only"
        echo "$S" | grep -qx "vsid" \
            && ok "voice_extn vsid/call_state — needed to start that session" \
            || no "voice_extn vsid/call_state — cannot mark the call active"
    fi
fi

# ── 3. mixer controls (root + tinymix) ───────────────────────────────
echo
echo "=== 3. Mixer controls ==="
if ! have_root; then
    unk "needs root"
else
    TM=""
    for p in /data/local/tmp/tinymix /vendor/bin/tinymix /system/bin/tinymix; do
        su_ "[ -x $p ] && echo yes" | grep -q yes && { TM=$p; break; }
    done
    if [ -z "$TM" ]; then
        unk "tinymix not present — push magisk/tinymix to /data/local/tmp/ (chmod 755)"
    else
        M=$(su_ "$TM")
        n=$(echo "$M" | grep -c 'Incall_Music Audio Mixer')
        [ "$n" -gt 0 ] && ok "Incall_Music Audio Mixer ($n ports)" || no "Incall_Music Audio Mixer"
        echo "$M" | grep -q VOC_REC_DL && ok "VOC_REC_DL / VOC_REC_UL" || no "VOC_REC_* capture routing"
        echo "$M" | grep -q "Voc Rec Config" && ok "Voc Rec Config" || no "Voc Rec Config"
    fi
fi

# ── verdict ──────────────────────────────────────────────────────────
echo
echo "=== Verdict ==="
if [ "$fail" -eq 0 ] && [ "$unknown" -eq 0 ]; then
    echo "  Fully supported on paper: $pass/$pass checks passed."
    echo "  A DeviceProfile entry will still be needed — the mixer names are"
    echo "  generic, but which front-end the playback track lands on is not."
    echo "  The 'Mixer BEFORE/AFTER' lines logged around each call show it."
elif [ "$fail" -eq 0 ]; then
    echo "  Promising: $pass checks passed, $unknown could not be checked."
    echo "  Root the device and re-run for a definite answer."
elif [ "$pass" -eq 0 ]; then
    echo "  Not supported: nothing required is present."
else
    echo "  Partial: $pass present, $fail missing, $unknown unchecked."
    echo "  Without incall_music there is no digital path to the caller;"
    echo "  without the in-call record usecases the agent can only hear the"
    echo "  caller acoustically, through the phone's own microphone."
fi
