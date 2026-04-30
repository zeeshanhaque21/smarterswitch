# Release keystore

`release.jks` signs every `flutter build apk --release`. It is checked in
deliberately — this is a personal-use Obtainium app, not Play-Store
distributed; the threat model treats the signing key the same as any other
project secret committed to a personal repo.

## Why it's committed

Before v0.11, releases were signed with whatever debug keystore happened to
exist on the build machine. That meant APKs built on different machines (or
after a fresh OS install) couldn't update each other in Obtainium — Android
refuses to install across mismatched signatures, requiring an uninstall +
fresh install per machine. Committing one stable keystore ends that.

## Credentials

```
keystore: app/android/keystore/release.jks
alias:    smarterswitch
storepass smarterswitch-dev
keypass:  smarterswitch-dev
```

## Used by

`app/android/app/build.gradle.kts` — the `signingConfigs.release` block
references this file by relative path. Every `flutter build apk --release`
or `flutter run --release` picks it up automatically.

## Rotating

If the keystore is ever compromised (or you decide to lock it down for a
real distribution channel), generate a new one:

```
keytool -genkey -noprompt \
  -keystore app/android/keystore/release.jks \
  -alias smarterswitch -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass NEWPASS -keypass NEWPASS \
  -dname "CN=SmarterSwitch, O=Personal, C=US"
```

Update the `storePassword` / `keyPassword` constants in `build.gradle.kts`
to match. **Every existing install must uninstall + reinstall** because
the new key won't match the old one.
