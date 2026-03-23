#!/bin/sh
# test-runner.sh — Integration test suite that runs inside the guest VM.
#
# Invoked by xinitrc when TEST_SUITE=1 is set in chrome-env.
# Each test writes PASS/FAIL to /dev/hvc0 (serial console) so the host
# can verify results. The overall result is a summary line at the end.
#
# Tests are structured as shell functions named test_*. Each must print
# exactly one result line:
#   PASS:<name>
#   FAIL:<name>:<reason>

SERIAL=/dev/hvc0
PASS=0
FAIL=0
ERRORS=""

pass() {
    PASS=$((PASS + 1))
    echo "PASS:$1" > $SERIAL
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS  FAIL:$1:$2\n"
    echo "FAIL:$1:$2" > $SERIAL
}

# Source chrome-env so we have access to all config variables
[ -f /tmp/bromure/chrome-env ] && . /tmp/bromure/chrome-env

# ===================================================================
# GENERAL
# ===================================================================

test_chrome_ready() {
    if [ -f /tmp/bromure/chrome-ready ]; then
        pass "chrome_ready"
    else
        fail "chrome_ready" "chrome-ready marker not found"
    fi
}

test_chrome_env_exists() {
    if [ -f /tmp/bromure/chrome-env ]; then
        pass "chrome_env_exists"
    else
        fail "chrome_env_exists" "/tmp/bromure/chrome-env not found"
    fi
}

test_home_page() {
    expected="$TEST_EXPECT_URL"
    [ -z "$expected" ] && { pass "home_page_skip"; return; }
    if echo "$CHROME_URL" | grep -qF "$expected"; then
        pass "home_page"
    else
        fail "home_page" "expected=$expected got=$CHROME_URL"
    fi
}

# ===================================================================
# APPEARANCE
# ===================================================================

test_dark_mode() {
    expected="$TEST_EXPECT_DARK_MODE"
    [ -z "$expected" ] && { pass "dark_mode_skip"; return; }
    if [ "$expected" = "1" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "\-\-force-dark-mode"; then
            pass "dark_mode_on"
        else
            fail "dark_mode_on" "--force-dark-mode not in EXTRA_FLAGS"
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "\-\-force-dark-mode"; then
            fail "dark_mode_off" "--force-dark-mode should not be in EXTRA_FLAGS"
        else
            pass "dark_mode_off"
        fi
    fi
}

# ===================================================================
# GPU / WEBGL
# ===================================================================

test_gpu() {
    expected="$TEST_EXPECT_GPU"
    [ -z "$expected" ] && { pass "gpu_skip"; return; }
    if [ "$expected" = "0" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "\-\-disable-gpu"; then
            pass "gpu_disabled"
        else
            fail "gpu_disabled" "--disable-gpu not in EXTRA_FLAGS"
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "\-\-disable-gpu"; then
            fail "gpu_enabled" "--disable-gpu should not be in EXTRA_FLAGS"
        else
            pass "gpu_enabled"
        fi
    fi
}

test_webgl() {
    expected="$TEST_EXPECT_WEBGL"
    [ -z "$expected" ] && { pass "webgl_skip"; return; }
    if [ "$expected" = "0" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "\-\-disable-webgl"; then
            pass "webgl_disabled"
        else
            fail "webgl_disabled" "--disable-webgl not in EXTRA_FLAGS"
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "\-\-disable-webgl"; then
            fail "webgl_enabled" "--disable-webgl should not be in EXTRA_FLAGS"
        else
            pass "webgl_enabled"
        fi
    fi
}

# ===================================================================
# AUDIO
# ===================================================================

test_audio() {
    expected="$TEST_EXPECT_AUDIO"
    [ -z "$expected" ] && { pass "audio_skip"; return; }
    if [ "$expected" = "1" ]; then
        if [ "$AUDIO" = "1" ]; then
            pass "audio_enabled"
        else
            fail "audio_enabled" "AUDIO not set to 1"
        fi
    else
        if [ "$AUDIO" = "1" ]; then
            fail "audio_disabled" "AUDIO should not be 1"
        else
            pass "audio_disabled"
        fi
    fi
}

test_audio_volume() {
    expected="$TEST_EXPECT_VOLUME"
    [ -z "$expected" ] && { pass "volume_skip"; return; }
    if [ "$AUDIO_VOLUME" = "$expected" ]; then
        pass "audio_volume"
    else
        fail "audio_volume" "expected=$expected got=$AUDIO_VOLUME"
    fi
}

# ===================================================================
# CLIPBOARD / FILE TRANSFER
# ===================================================================

test_clipboard() {
    expected="$TEST_EXPECT_CLIPBOARD"
    [ -z "$expected" ] && { pass "clipboard_skip"; return; }
    if [ "$expected" = "1" ]; then
        if [ "$CLIPBOARD" = "1" ]; then
            pass "clipboard_enabled"
        else
            fail "clipboard_enabled" "CLIPBOARD not set"
        fi
    else
        if [ "$CLIPBOARD" = "1" ]; then
            fail "clipboard_disabled" "CLIPBOARD should not be set"
        else
            pass "clipboard_disabled"
        fi
    fi
}

test_file_transfer() {
    expected="$TEST_EXPECT_FILE_TRANSFER"
    [ -z "$expected" ] && { pass "file_transfer_skip"; return; }
    if [ "$expected" = "1" ]; then
        if [ "$FILE_TRANSFER" = "1" ]; then
            pass "file_transfer_enabled"
        else
            fail "file_transfer_enabled" "FILE_TRANSFER not set"
        fi
    else
        if [ "$FILE_TRANSFER" = "1" ]; then
            fail "file_transfer_disabled" "FILE_TRANSFER should not be set"
        else
            pass "file_transfer_disabled"
        fi
    fi
}

# ===================================================================
# DOWNLOAD BLOCKING
# ===================================================================

test_download_policy() {
    expected="$TEST_EXPECT_BLOCK_DOWNLOADS"
    [ -z "$expected" ] && { pass "download_policy_skip"; return; }
    policy_file="/etc/chromium/policies/managed/session.json"
    if [ ! -f "$policy_file" ]; then
        fail "download_policy" "session.json not found"
        return
    fi
    has_block=$(cat "$policy_file" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('DownloadRestrictions',0))" 2>/dev/null)
    if [ "$expected" = "1" ]; then
        if [ "$has_block" = "3" ]; then
            pass "download_blocked"
        else
            fail "download_blocked" "DownloadRestrictions=$has_block expected=3"
        fi
    else
        if [ "$has_block" = "3" ]; then
            fail "download_allowed" "DownloadRestrictions=3 but should not be"
        else
            pass "download_allowed"
        fi
    fi
}

test_download_guard() {
    expected="$TEST_EXPECT_BLOCK_DOWNLOADS"
    [ -z "$expected" ] && { pass "download_guard_skip"; return; }
    if [ "$expected" = "1" ]; then
        if pgrep -f download-guard > /dev/null; then
            pass "download_guard_running"
        else
            fail "download_guard_running" "download-guard.sh not running"
        fi
    else
        if pgrep -f download-guard > /dev/null; then
            fail "download_guard_stopped" "download-guard.sh should not be running"
        else
            pass "download_guard_stopped"
        fi
    fi
}

# ===================================================================
# PROXY
# ===================================================================

test_proxy() {
    expected_host="$TEST_EXPECT_PROXY_HOST"
    [ -z "$expected_host" ] && { pass "proxy_skip"; return; }
    if echo "$EXTRA_FLAGS" | grep -qF "$expected_host"; then
        pass "proxy_configured"
    else
        fail "proxy_configured" "proxy host $expected_host not found in EXTRA_FLAGS"
    fi
}

test_internal_proxy() {
    expected="$TEST_EXPECT_INTERNAL_PROXY"
    [ -z "$expected" ] && { pass "internal_proxy_skip"; return; }
    if [ "$expected" = "1" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "127.0.0.1:3128"; then
            pass "internal_proxy_on"
        else
            fail "internal_proxy_on" "internal proxy not in EXTRA_FLAGS"
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "127.0.0.1:3128"; then
            fail "internal_proxy_off" "internal proxy should not be in EXTRA_FLAGS"
        else
            pass "internal_proxy_off"
        fi
    fi
}

# ===================================================================
# DNS / AD BLOCKING / MALWARE
# ===================================================================

test_dnsmasq() {
    expected="$TEST_EXPECT_DNSMASQ"
    [ -z "$expected" ] && { pass "dnsmasq_skip"; return; }
    if [ "$expected" = "1" ]; then
        if pgrep -x dnsmasq > /dev/null; then
            pass "dnsmasq_running"
        else
            fail "dnsmasq_running" "dnsmasq not running"
        fi
    else
        if pgrep -x dnsmasq > /dev/null; then
            fail "dnsmasq_stopped" "dnsmasq should not be running"
        else
            pass "dnsmasq_stopped"
        fi
    fi
}

test_squid() {
    expected="$TEST_EXPECT_SQUID"
    [ -z "$expected" ] && { pass "squid_skip"; return; }
    if [ "$expected" = "1" ]; then
        if pgrep -x squid > /dev/null; then
            pass "squid_running"
        else
            fail "squid_running" "squid not running"
        fi
    else
        if pgrep -x squid > /dev/null; then
            fail "squid_stopped" "squid should not be running"
        else
            pass "squid_stopped"
        fi
    fi
}

test_malware_dns() {
    expected="$TEST_EXPECT_MALWARE_DNS"
    [ -z "$expected" ] && { pass "malware_dns_skip"; return; }
    conf="/etc/dnsmasq.d/pihole.conf"
    [ ! -f "$conf" ] && { fail "malware_dns" "pihole.conf not found"; return; }
    if [ "$expected" = "1" ]; then
        if grep -q "server=1.1.1.2" "$conf"; then
            pass "malware_dns_enabled"
        else
            fail "malware_dns_enabled" "Cloudflare security DNS (1.1.1.2) not configured"
        fi
    else
        if grep -q "server=1.1.1.2" "$conf"; then
            fail "malware_dns_disabled" "Cloudflare security DNS should not be configured"
        else
            pass "malware_dns_disabled"
        fi
    fi
}

# ===================================================================
# EXTENSIONS
# ===================================================================

test_phishing_extension() {
    expected="$TEST_EXPECT_PHISHING"
    [ -z "$expected" ] && { pass "phishing_skip"; return; }
    if [ "$expected" = "1" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "phishing-guard"; then
            pass "phishing_extension_loaded"
        else
            fail "phishing_extension_loaded" "phishing-guard not in EXTRA_FLAGS"
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "phishing-guard"; then
            fail "phishing_extension_not_loaded" "phishing-guard should not be loaded"
        else
            pass "phishing_extension_not_loaded"
        fi
    fi
}

test_link_sender_extension() {
    expected="$TEST_EXPECT_LINK_SENDER"
    [ -z "$expected" ] && { pass "link_sender_skip"; return; }
    if [ "$expected" = "1" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "link-sender"; then
            pass "link_sender_loaded"
        else
            fail "link_sender_loaded" "link-sender not in EXTRA_FLAGS"
        fi
    fi
}

# ===================================================================
# WEBRTC BLOCKING
# ===================================================================

test_webrtc_policy() {
    expected="$TEST_EXPECT_WEBRTC_BLOCKED"
    [ -z "$expected" ] && { pass "webrtc_skip"; return; }
    policy_file="/etc/chromium/policies/managed/session.json"
    if [ "$expected" = "1" ]; then
        if echo "$EXTRA_FLAGS" | grep -q "disable_non_proxied_udp"; then
            pass "webrtc_flags_blocked"
        else
            fail "webrtc_flags_blocked" "WebRTC blocking flags not in EXTRA_FLAGS"
        fi
        if [ -f "$policy_file" ]; then
            has_policy=$(cat "$policy_file" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('WebRtcIPHandlingPolicy',''))" 2>/dev/null)
            if [ "$has_policy" = "disable_non_proxied_udp" ]; then
                pass "webrtc_policy_blocked"
            else
                fail "webrtc_policy_blocked" "WebRTC policy not set"
            fi
        fi
    else
        if echo "$EXTRA_FLAGS" | grep -q "disable_non_proxied_udp"; then
            fail "webrtc_flags_allowed" "WebRTC flags should not be set"
        else
            pass "webrtc_flags_allowed"
        fi
    fi
}

# ===================================================================
# MEDIA DEVICES (camera/mic policy)
# ===================================================================

test_media_policy() {
    policy_file="/etc/chromium/policies/managed/session.json"
    [ ! -f "$policy_file" ] && { pass "media_policy_skip"; return; }

    expected_cam="$TEST_EXPECT_WEBCAM"
    expected_mic="$TEST_EXPECT_MICROPHONE"
    [ -z "$expected_cam" ] && [ -z "$expected_mic" ] && { pass "media_policy_skip"; return; }

    cam_policy=$(cat "$policy_file" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('VideoCaptureAllowed','')).lower())" 2>/dev/null)
    mic_policy=$(cat "$policy_file" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('AudioCaptureAllowed','')).lower())" 2>/dev/null)

    if [ -n "$expected_cam" ]; then
        exp_val=$([ "$expected_cam" = "1" ] && echo "true" || echo "false")
        if [ "$cam_policy" = "$exp_val" ]; then
            pass "webcam_policy"
        else
            fail "webcam_policy" "expected=$exp_val got=$cam_policy"
        fi
    fi

    if [ -n "$expected_mic" ]; then
        exp_val=$([ "$expected_mic" = "1" ] && echo "true" || echo "false")
        if [ "$mic_policy" = "$exp_val" ]; then
            pass "microphone_policy"
        else
            fail "microphone_policy" "expected=$exp_val got=$mic_policy"
        fi
    fi
}

# ===================================================================
# LOCALE
# ===================================================================

test_locale() {
    expected="$TEST_EXPECT_LOCALE"
    [ -z "$expected" ] && { pass "locale_skip"; return; }
    chrome_lang_expected=$(echo "$expected" | tr '_' '-')
    if echo "$CHROME_LANG" | grep -qF "$chrome_lang_expected"; then
        pass "locale_chrome_lang"
    else
        fail "locale_chrome_lang" "expected=$chrome_lang_expected got=$CHROME_LANG"
    fi
    if echo "$LANG" | grep -qF "$expected"; then
        pass "locale_lang_env"
    else
        fail "locale_lang_env" "expected=$expected in LANG, got=$LANG"
    fi
}

# ===================================================================
# CUSTOM ROOT CAs
# ===================================================================

test_custom_cas() {
    expected="$TEST_EXPECT_CA_COUNT"
    [ -z "$expected" ] && { pass "custom_cas_skip"; return; }
    ca_dir="/tmp/bromure/custom-cas"
    if [ "$expected" = "0" ]; then
        if [ ! -d "$ca_dir" ] || [ -z "$(ls -A $ca_dir 2>/dev/null)" ]; then
            pass "no_custom_cas"
        else
            fail "no_custom_cas" "CA files found but none expected"
        fi
    else
        actual=$(ls -1 "$ca_dir"/*.crt 2>/dev/null | wc -l | tr -d ' ')
        if [ "$actual" = "$expected" ]; then
            pass "custom_cas_count"
        else
            fail "custom_cas_count" "expected=$expected got=$actual"
        fi
    fi
}

# ===================================================================
# CMD/CTRL SWAP
# ===================================================================

test_swap_cmd_ctrl() {
    expected="$TEST_EXPECT_SWAP_CMD_CTRL"
    [ -z "$expected" ] && { pass "swap_cmd_ctrl_skip"; return; }
    if [ "$expected" = "1" ]; then
        if [ "$SWAP_CMD_CTRL" = "1" ]; then
            pass "swap_cmd_ctrl_on"
        else
            fail "swap_cmd_ctrl_on" "SWAP_CMD_CTRL not set"
        fi
    else
        if [ "$SWAP_CMD_CTRL" = "1" ]; then
            fail "swap_cmd_ctrl_off" "SWAP_CMD_CTRL should not be set"
        else
            pass "swap_cmd_ctrl_off"
        fi
    fi
}

# ===================================================================
# PROFILE DISK
# ===================================================================

test_profile_disk() {
    expected="$TEST_EXPECT_PROFILE_DIR"
    [ -z "$expected" ] && { pass "profile_disk_skip"; return; }
    if [ -d "$expected" ]; then
        pass "profile_dir_exists"
    else
        fail "profile_dir_exists" "$expected not found"
    fi
    if echo "$EXTRA_FLAGS" | grep -qF "user-data-dir=$expected"; then
        pass "profile_dir_flag"
    else
        fail "profile_dir_flag" "--user-data-dir=$expected not in EXTRA_FLAGS"
    fi
}

# ===================================================================
# USER AGENT
# ===================================================================

test_user_agent() {
    expected="$TEST_EXPECT_USER_AGENT"
    [ -z "$expected" ] && { pass "user_agent_skip"; return; }
    if echo "$EXTRA_FLAGS" | grep -qF "Bromure/"; then
        pass "user_agent_suffix"
    else
        fail "user_agent_suffix" "Bromure/ user-agent suffix not in EXTRA_FLAGS"
    fi
}

# ===================================================================
# NETWORK CONNECTIVITY
# ===================================================================

test_dns_resolution() {
    if nslookup www.google.com > /dev/null 2>&1; then
        pass "dns_resolution"
    else
        fail "dns_resolution" "cannot resolve www.google.com"
    fi
}

test_internet_access() {
    if wget -q -O /dev/null --timeout=5 http://www.google.com 2>/dev/null; then
        pass "internet_access"
    else
        fail "internet_access" "cannot reach http://www.google.com"
    fi
}

# ===================================================================
# RUNNER
# ===================================================================

echo "TEST_SUITE_START" > $SERIAL

test_chrome_ready
test_chrome_env_exists
test_home_page
test_dark_mode
test_gpu
test_webgl
test_audio
test_audio_volume
test_clipboard
test_file_transfer
test_download_policy
test_download_guard
test_proxy
test_internal_proxy
test_dnsmasq
test_squid
test_malware_dns
test_phishing_extension
test_link_sender_extension
test_webrtc_policy
test_media_policy
test_locale
test_custom_cas
test_swap_cmd_ctrl
test_profile_disk
test_user_agent
test_dns_resolution
test_internet_access

echo "TEST_SUITE_DONE:pass=$PASS:fail=$FAIL" > $SERIAL
if [ $FAIL -gt 0 ]; then
    printf "$ERRORS" > $SERIAL
fi
