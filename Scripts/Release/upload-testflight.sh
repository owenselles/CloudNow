#!/bin/bash
# Upload with an Individual API key; no Issuer ID or Apple ID password is used.
set +x
set -euo pipefail
: "${ASC_PRIVATE_KEY:?Set ASC_PRIVATE_KEY}" "${ASC_KEY_ID:?Set ASC_KEY_ID}"
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 1

jwt="$(ruby -ropenssl -rjson -rbase64 <<'RUBY'
key = OpenSSL::PKey.read(ENV.fetch("ASC_PRIVATE_KEY"))
abort "Expected a P-256 private key" unless
  key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == "prime256v1"
encode = ->(data) { Base64.urlsafe_encode64(data, padding: false) }
now = Time.now.to_i
header = { alg: "ES256", kid: ENV.fetch("ASC_KEY_ID"), typ: "JWT" }
payload = { sub: "user", aud: "appstoreconnect-v1", iat: now, exp: now + 1200 }
data = [header, payload].map { |part| encode.call(JSON.generate(part)) }.join(".")
signature = OpenSSL::ASN1.decode(key.sign("SHA256", data)).value.map do |integer|
  integer.value.to_s(2).rjust(32, "\x00")
end.join
abort "Invalid ES256 signature" unless signature.bytesize == 64
puts "#{data}.#{encode.call(signature)}"
RUBY
)"
printf '::add-mask::%s\n' "$jwt"
unset ASC_PRIVATE_KEY

/usr/local/itms/bin/iTMSTransporter -m upload \
  -assetFile "$RUNNER_TEMP/testflight-export/CloudNow.ipa" \
  -jwt "$jwt" -v informational
printf 'Uploaded to App Store Connect. Apple processing and tester distribution follow separately.\n' >> "$GITHUB_STEP_SUMMARY"
