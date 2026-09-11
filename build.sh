#!/bin/bash
# Builds Lidbend.app from the Swift package.
#
#   ./build.sh            release build into ./dist/Lidbend.app
#   ./build.sh --debug    debug build
#   ./build.sh --run      build, then relaunch the app
#   ./build.sh --package  build, then zip the app for a GitHub release

set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
RUN=0
PACKAGE=0
SETUP_SIGNING=0
SIGN_ID="Lidbend Local"

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --run)   RUN=1 ;;
        --package) PACKAGE=1 ;;
        --setup-signing) SETUP_SIGNING=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Creates a local self-signed code-signing certificate.
#
# Screen Recording consent is bound to the code signature. An ad-hoc signature
# is identified by its cdhash, which changes on every rebuild, so macOS treats
# each build as a new app and asks for permission again. Signing with a stable
# certificate keeps one grant valid across rebuilds.
#
# This touches your login keychain and macOS will ask for your password to trust
# the certificate. It is only needed once.
setup_signing() {
    if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
        echo "==> certificate '$SIGN_ID' already exists"
        return
    fi

    local dir
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN

    cat > "$dir/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = Lidbend Local
[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

    echo "==> generating certificate"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/openssl.cnf" 2>/dev/null
    # macOS cannot read the AES/PBKDF2 bundles OpenSSL 3 writes by default, so
    # pin the legacy algorithms its importer understands.
    openssl pkcs12 -export -out "$dir/id.p12" -inkey "$dir/key.pem" \
        -in "$dir/cert.pem" -name "$SIGN_ID" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout pass:lidbend

    echo "==> importing into the login keychain"
    security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -T /usr/bin/codesign -P lidbend >/dev/null

    echo "==> trusting it for code signing (macOS will ask for your password)"
    security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" \
        "$dir/cert.pem"

    echo "==> done. Rebuild, then grant Screen Recording one final time."
}

if [ "$SETUP_SIGNING" = "1" ]; then
    setup_signing
    exit 0
fi

APP="dist/Lidbend.app"
BIN=".build/$CONFIG/Lidbend"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lidbend"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer the stable local certificate so the Screen Recording grant survives
# rebuilds. Without it, fall back to an ad-hoc signature, which macOS treats as
# a different app after every build.
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "==> codesign ($SIGN_ID)"
    codesign --force --sign "$SIGN_ID" --identifier app.lidbend.Lidbend \
        --options runtime --timestamp=none "$APP"
else
    echo "==> codesign (ad-hoc)"
    echo "    note: macOS will ask for Screen Recording again after each rebuild."
    echo "    run ./build.sh --setup-signing once to stop that."
    codesign --force --sign - --identifier app.lidbend.Lidbend \
        --options runtime --timestamp=none "$APP" >/dev/null 2>&1 \
        || codesign --force --sign - --identifier app.lidbend.Lidbend "$APP"
fi

echo "==> built $APP"

# ditto keeps the code signature and resource forks intact, which a plain zip
# does not; the archive unpacks to a working app on another Mac.
if [ "$PACKAGE" = "1" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    ZIP="dist/Lidbend-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> packaged $ZIP"
fi

if [ "$RUN" = "1" ]; then
    pkill -x Lidbend 2>/dev/null || true
    sleep 0.5
    open "$APP"
    echo "==> launched"
fi
