# SiriFix — تويك يمنع كراش VK داخل LiveContainer

## المشكلة

تطبيق VK الرسمي يطيح فور فتحه داخل LiveContainer بهذه الرسالة:

> `Use of the class <INPreferences: ...> from an app requires the entitlement com.apple.developer.siri.`

السبب: LiveContainer يشغّل التطبيق داخل عمليته هو، فـ iOS يفحص صلاحيات LiveContainer مو صلاحيات VK، وصلاحية `com.apple.developer.siri` الخاصة بـ VK ما تننسخ للمضيف. فريق LiveContainer قال إنه ما راح يصلحها (FAQ 8.2، ونفس المشكلة في issue #1492).

## الحل

تويك `SiriFix.dylib` يعترض نداءات SiriKit قبل ما يشتغل كود Apple الأصلي (هو اللي يرمي الاستثناء):

- `+[INPreferences siriAuthorizationStatus]` ← يرجع **Denied (2)** بدل ما ينادي الأصلي
- `+[INPreferences requestSiriAuthorization:]` ← ينادي الـ completion block فورًا بـ **Denied (2)**
- `-[INPreferences init]` ← يتجاوز الـ init الأصلي (فيه فحص الصلاحية) وينادي `NSObject init` فقط

التويك يستخدم Objective-C runtime فقط، بدون CydiaSubstrate، ويتركّب عند تحميل المكتبة قبل ما يشتغل كود VK.

## ⚠️ تجريبي — بدون ضمان

التويك يغطي مسار `INPreferences` فقط، وهو المسار الظاهر في لوق الكراش. إذا VK يوصل لفحص الصلاحية من selector ثاني، ممكن يطيح برضه — وفي هذي الحالة لوق الكراش الجديد هو التشخيص التالي. ميزات Siri داخل VK ما راح تشتغل (وهذا مقصود — التطبيق يكمل بدونها).

## التثبيت في LiveContainer

1. حمّل `SiriFix.dylib` من صفحة الـ Releases في هذا المستودع (أو من الـ artifact `SiriFix-dylib` في Actions).
2. في LiveContainer: افتح مدير التويكات واستورد ملف الـ `.dylib` (هو يوقّعه تلقائيًا في وضع JIT-less)، **أو** انسخ الملف يدويًا إلى مجلد `Tweaks` العام داخل `Documents` في LiveContainer.
3. اضغط مطولًا على أيقونة VK في LiveContainer وتأكد أن مجلد التويكات المختار هو المجلد اللي فيه `SiriFix.dylib`.
4. أغلق VK تمامًا وأعد فتحه من داخل LiveContainer.
5. للتأكد: التويك يطبع `[SiriFix] installed` في لوق الجهاز عند التحميل.

## إذا ما زال يطيح

أرسل لوق الكراش الجديد — إذا تغيّر السطر الأول عن `INPreferences` فالمشكلة صارت شي ثاني، والتويك سوّى شغله.

---

## English

## The problem

The official VK client crashes immediately on launch inside LiveContainer:

> `Use of the class <INPreferences: ...> from an app requires the entitlement com.apple.developer.siri.`

Cause: LiveContainer runs the guest app inside its own process, so iOS checks LiveContainer's entitlements, not VK's, and the guest's `com.apple.developer.siri` entitlement is not copied to the host. LiveContainer upstream will not fix this (FAQ 8.2; same issue as #1492).

## The fix

The `SiriFix.dylib` tweak intercepts the SiriKit calls before Apple's original code (which throws) runs:

- `+[INPreferences siriAuthorizationStatus]` → returns **Denied (2)**
- `+[INPreferences requestSiriAuthorization:]` → calls the completion block immediately with **Denied (2)**
- `-[INPreferences init]` → bypasses the original init (which performs the entitlement check) and calls `NSObject init` only

Pure Objective-C runtime swizzling, no CydiaSubstrate dependency. It installs via a `constructor` at dylib load time, before VK's launch code runs.

## ⚠️ Experimental — no guarantee

The tweak only covers the `INPreferences` path shown in the crash log. If VK reaches the entitlement check through a different selector, it may still crash — in that case the new crash log is the next diagnostic. Siri features inside VK will report "not authorized", which is intended.

## Install in LiveContainer

1. Download `SiriFix.dylib` from this repo's Releases page (or the `SiriFix-dylib` artifact in Actions).
2. In LiveContainer: import the `.dylib` with the built-in tweak manager (it signs it in JIT-less mode), **or** copy it manually into the global `Tweaks` folder inside LiveContainer's `Documents`.
3. Long-press the VK icon in LiveContainer and make sure the selected tweak folder is the one containing `SiriFix.dylib`.
4. Force-quit VK and relaunch it from inside LiveContainer.
5. To verify: the tweak logs `[SiriFix] installed` to the device console when loaded.

## If it still crashes

Send the new crash log — if the first line is no longer about `INPreferences`, the problem has moved on and the tweak did its job.

## Build

Pushing to `main` builds on `macos-latest` with:

```sh
clang -arch arm64 -target arm64-apple-ios15.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -dynamiclib -framework Foundation -framework Intents -fobjc-arc -O2 \
  -o SiriFix.dylib SiriFix.m
```

The workflow verifies the output (`file`, `lipo -verify_arch arm64`, `nm`, `__mod_init_func`) and publishes it as an artifact and a release asset.
