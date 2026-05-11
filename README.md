# image_to_pdf

Flutter ile yazılmış bir **belge fotoğrafı iyileştirme** uygulaması. Kullanıcı galeriden seçer veya kamerayla çeker, isteğe bağlı kırpar; ardından **Gaussian blur + “magic color” (bölme)** hattıyla metnin okunabilirliğini artırmaya yönelik bir JPEG üretir ve paylaşır veya galeriye kaydeder.

> **Not:** Depo adı `image_to_pdf` olsa da mevcut `lib/main.dart` kodu PDF üretmez; arayüz başlığı **Doc Scanner** şeklindedir. PDF özelliği eklenecekse ayrı bir paket ve akış gerekir.

---

## Yeni geliştirici için hızlı özet

| Konu | Açıklama |
|------|-----------|
| **Dil / çatı** | Dart 3, Flutter (Material 3) |
| **Ana giriş** | `lib/main.dart` — tek dosyada UI + iş pipeline’ı |
| **Ağır iş** | `dart:isolate` ile decode, yeniden boyutlandırma ve piksel işleme ana thread’i bloklamasın diye arka planda |
| **Native görüntü** | `packages/opencv_4` — vendored OpenCV sarmalayıcısı (pub.dev sürümü yerine `path`) |

---

## Gereksinimler

- [Flutter SDK](https://docs.flutter.dev/get-started/install) — `pubspec.yaml` içinde `sdk: ^3.11.1` ile uyumlu bir Dart sürümü
- **Android:** Android Studio veya en azından Android SDK + lisanslar; derleme için JDK
- **iOS (yalnızca macOS):** Xcode, CocoaPods (`cd ios && pod install` gerekirse)
- **Windows masaüstü:** Bu proje şu an mobil odaklı native eklentiler kullanıyor; tam destek için Android/iOS hedefleyin

Kurulum doğrulaması:

```bash
flutter doctor -v
```

---

## Projeyi çalıştırma

Depo kökünde:

```bash
flutter pub get
flutter run
```

Belirli cihaz:

```bash
flutter devices
flutter run -d <cihaz_id>
```

Analiz ve test:

```bash
flutter analyze
flutter test
```

---

## Kullanıcı akışı (ne oluyor?)

1. **Resim ekle** — alt kısımdaki FAB; galeri veya kamera.
2. **Kırpma** — `image_cropper` (Android’de uCrop) açılır; iptal veya hata durumunda orijinal seçimle devam edilir.
3. **İşle** — `_runScannerPipeline`:
   - Çok büyük görseller `_kMaxProcessSide` (2048 px) ile sınırlandırılır; gerekirse geçici JPEG yazılır.
   - **OpenCV** tarafında `Cv2.gaussianBlur` (çekirdek 71×71) ile bulanık kopya alınır.
   - **Dart `image` paketi** ile orijinal ÷ bulanık (“divide” / magic color) + hafif doygunluk/kontrast, çıktı JPEG.
4. **Paylaş / Kaydet** — `share_plus` ile dosya paylaşımı; mobilde `gal` ile Fotoğraflar’a kayıt (web’de kayıt yerine bilgi mesajı).

Geniş ekranda orijinal ve işlenmiş **yan yana**; dar ekranda **segmented** ile geçiş.

---

## Mimari ve dosya yapısı

```
image_to_pdf/
├── lib/
│   └── main.dart          # Uygulama: DocScannerApp, pipeline, UI
├── packages/
│   └── opencv_4/          # Yerel OpenCV eklentisi (path bağımlılık)
├── android/               # İzinler, uCrop activity
├── ios/                   # Info.plist kullanım açıklamaları
├── pubspec.yaml
└── analysis_options.yaml
```

- **Stateful ana sayfa:** `_DocScannerHomePageState` — seçilen dosya yolu, işlenmiş `Uint8List`, yükleme bayrağı.
- **Isolate yardımcıları:** `_prepareScanOffMain`, `_magicColorOffMain` — web’de `Isolate.run` kullanılmaz (`kIsWeb` dalları).

Yeni özellik eklerken büyük i/o veya piksel döngüsünü mümkünse isolate veya `compute` ile tutmak performans için önemlidir.

---

## Bağımlılıklar (yüksek seviye)

| Paket | Rol |
|--------|-----|
| `opencv_4` (`path: packages/opencv_4`) | Gaussian blur vb. native OpenCV |
| `image_picker` | Galeri / kamera |
| `image_cropper` | Native kırpma UI |
| `image` | Decode/encode, resize, piksel işleme |
| `share_plus` | İşlenmiş JPEG paylaşımı |
| `path_provider` | Paylaşım için geçici dosya yolu |
| `gal` | iOS/Android galeriye yazma |

`pubspec.yaml` içinde `provider` tanımlı olsa da şu an `lib/main.dart` içinde kullanılmıyor; state yönetimi tamamen `setState` ile.

---

## Platform notları

### Android (`android/app/src/main/AndroidManifest.xml`)

- `CAMERA`, eski API’ler için `WRITE_EXTERNAL_STORAGE` (maxSdk 29)
- `com.yalantis.ucrop.UCropActivity` — `image_cropper` için gerekli
- Çok büyük bitmap’lerde uCrop sınır taşması olabiliyor; kod `maxWidth`/`maxHeight` ile ve hata durumunda orijinale düşerek bunu yumuşatıyor

### iOS (`ios/Runner/Info.plist`)

- `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSCameraUsageDescription` — App Store ve çalışma zamanı için zorunlu açıklamalar

### Web

- OpenCV ve dosya yolları mobil odaklıdır; `kIsWeb` dallarında isolate devre dışı, kırpma atlanır, galeri kaydı uyarı verir. Web’i birinci sınıf hedef yapacaksanız ayrı test ve muhtemelen farklı iş pipeline’ı gerekir.

---

## `opencv_4` neden projede?

`pubspec.yaml` yorumunda belirtildiği gibi, pub.dev’deki bazı sürümler güncel Android Gradle Plugin / namespace veya eski Registrar API’leriyle uyumsuz olabiliyor. Bu yüzden **`packages/opencv_4` altında vendored** bir kopya kullanılıyor. Bu paketi güncellerken native taraftaki kırılmaları göz önünde bulundurun.

---

## Sorun giderme

- **`flutter pub get` hatası:** `packages/opencv_4` yolunun bozulmadığından emin olun.
- **Kırpma sonrası siyah / boş görüntü:** Çözünürlük sınırları veya uCrop hatası; log’da `image_cropper` mesajlarına bakın.
- **OpenCV hata snackbar’ı:** Native plugin dönüşü boş veya platform istisnası; gerçek cihazda ve güncel build’de deneyin.

---

## Faydalı bağlantılar

- [Flutter dokümantasyonu](https://docs.flutter.dev/)
- [Dart dil rehberi](https://dart.dev/guides)
- [image_picker](https://pub.dev/packages/image_picker), [image_cropper](https://pub.dev/packages/image_cropper), [image](https://pub.dev/packages/image)

---

## Lisans / yayınlama

`pubspec.yaml` içinde `publish_to: 'none'` — bu paket pub.dev’e yayınlanmak üzere yapılandırılmamış özel uygulama projesidir.
