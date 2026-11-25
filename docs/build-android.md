# RustDesk Android (APK) 编译指南

本文档介绍如何在本地（以 macOS 为例，Linux 同理）从源码编译 RustDesk 的 Android APK。
RustDesk 的 Android 端由两部分组成：

1. **Rust 核心库**（`librustdesk.so`）：通过 `cargo-ndk` 交叉编译为 Android 原生库。
2. **Flutter UI**：打包为 APK。

二者都需要一组 vcpkg 预编译的第三方依赖（如 `libvpx`、`aom`、`opus`、`libyuv`、`ffmpeg`、`oboe` 等），
这些依赖通过 vcpkg 在本地编译并安装。

---

## 1. 环境要求

| 工具 | 版本 / 说明 | 来源 |
| --- | --- | --- |
| Rust 工具链 | `1.75`（Android 构建官方锁定版本） | rustup |
| cargo-ndk | `3.1.2`（`--locked`） | cargo install |
| Flutter SDK | `3.24.5`（stable） | flutter 官方 |
| Android SDK | compileSdk 34，build-tools 34.0.0 | Android Studio / sdkmanager |
| Android NDK | `r28c`（≥ r25c 即可） | sdkmanager |
| vcpkg | commit `120deac3062162151622ca4860575a33844ba10b` | git clone |
| cmake / ninja / nasm | 编译 vcpkg 依赖必需 | 包管理器 |
| JDK | 17 | 系统/SDKMAN |

> 注意：`app/build.gradle` 在配置阶段会执行 `cargo metadata` 并在 `release` 构建中引用
> `rustls-platform-verifier-android` 的 maven 目录，因此 **必须先把 Rust 核心库编译完成**，
> 再执行 `flutter build apk`。

---

## 2. 安装构建依赖

```bash
# macOS（Homebrew）
brew install cmake ninja nasm

# Ubuntu / Debian
sudo apt-get install -y cmake ninja-build nasm clang llvm-dev pkg-config
```

安装 Flutter 3.24.5（若已安装其它版本，建议用 `flutter channel stable && flutter upgrade` 对齐，
或单独放置 3.24.5 并在 `local.properties` 中指定 `flutter.sdk`）。

确认 Android SDK / NDK 已安装：

```bash
sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;28.0.13004108"
```

---

## 3. 安装 Rust 工具链与 cargo-ndk

```bash
# 安装 rustup（若尚未安装）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.75
source "$HOME/.cargo/env"

# 安装 cargo-ndk（构建 Android .so 必需）
cargo install cargo-ndk --version 3.1.2 --locked

# 添加 Android 目标架构（按需选择，下面仅 arm64 即可产出单个 arm64 APK）
rustup target add aarch64-linux-android
# 若需要其它架构：
# rustup target add armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

---

## 4. 准备 vcpkg

```bash
export VCPKG_COMMIT=120deac3062162151622ca4860575a33844ba10b
git clone https://github.com/microsoft/vcpkg.git "$HOME/vcpkg"
cd "$HOME/vcpkg"
git checkout "$VCPKG_COMMIT"
./bootstrap-vcpkg.sh
export VCPKG_ROOT="$HOME/vcpkg"
```

---

## 5. 设置环境变量

```bash
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/28.0.13004108"   # macOS 路径，Linux 改为 ~/Android/Sdk/ndk/<ver>
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export VCPKG_ROOT="$HOME/vcpkg"
```

> 脚本 `flutter/build_android_deps.sh` 与 `flutter/ndk_arm64.sh` 依赖上述变量，请务必导出。

---

## 6. 编译第三方依赖（vcpkg）

```bash
cd <rustdesk 仓库根目录>
./flutter/build_android_deps.sh arm64-v8a
```

该步骤会按 `vcpkg.json` 中的 `arm64-android` triplet 编译 `libvpx`、`aom`、`opus`、
`libyuv`、`ffmpeg`、`oboe`、`libjpeg-turbo`、`cpu-features` 等，耗时较长（通常数十分钟）。

---

## 7. 编译 Rust 核心库并放置到 jniLibs

```bash
cd <rustdesk 仓库根目录>
./flutter/ndk_arm64.sh

mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/liblibrustdesk.so \
   flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so

# 拷贝 NDK 自带的 C++ 运行时
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
   flutter/android/app/src/main/jniLibs/arm64-v8a/
# 注：Linux 上预编译目录为 linux-x86_64
```

其它架构对应的脚本与目录名：

| 架构 | 脚本 | jniLibs 子目录 | NDK 目标目录 |
| --- | --- | --- | --- |
| arm64-v8a | `ndk_arm64.sh` | `arm64-v8a` | `aarch64-linux-android` |
| armeabi-v7a | `ndk_arm.sh` | `armeabi-v7a` | `arm-linux-androideabi` |
| x86_64 | `ndk_x64.sh` | `x86_64` | `x86_64-linux-android` |
| x86 | `ndk_x86.sh` | `x86` | `i686-linux-android` |

---

## 8. 配置签名

`flutter/android/app/build.gradle` 在 `release` 构建时读取 `flutter/android/key.properties`：

```properties
# flutter/android/key.properties
storeFile=key.jks
storePassword=<你的密码>
keyAlias=rustdesk
keyPassword=<你的密码>
```

生成签名密钥库（请替换为自己的密码与别名）：

```bash
cd flutter/android/app
keytool -genkey -v -keystore key.jks -keyalg RSA -keysize 2048 -validity 10000 \
        -alias rustdesk -storepass <你的密码> -keypass <你的密码> \
        -dname "CN=rustdesk, OU=rustdesk, O=rustdesk, L=, S=, C=CN"
cd -
```

> 若仅做调试验证，也可把 `app/build.gradle` 中 `signingConfig signingConfigs.release`
> 临时改为 `signingConfigs.debug`，使用 Android 默认调试密钥。

---

## 9. 打包 APK

```bash
cd flutter
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

产物位于：

```
flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

如需一次打包全部架构，去掉 `--target-platform` 与 `--split-per-abi` 即可生成 universal APK。

---

## 10. 重新签名（可选）

若使用调试密钥或需要单独对齐/签名：

```bash
# 对齐
"$ANDROID_HOME/build-tools/34.0.0/zipalign" -p 4 \
    app-arm64-v8a-release.apk app-arm64-v8a-release-aligned.apk

# 签名
"$ANDROID_HOME/build-tools/34.0.0/apksigner" sign \
    --ks flutter/android/app/key.jks \
    --ks-key-alias rustdesk \
    --ks-pass pass:<你的密码> \
    --key-pass pass:<你的密码> \
    --out rustdesk.apk app-arm64-v8a-release-aligned.apk
```

---

## 11. 常见问题

- **`cargo metadata` 报错 / 找不到 rustls-platform-verifier maven 目录**：
  第 7 步的 Rust 库尚未编译，先执行 `ndk_arm64.sh`。
- **vcpkg 编译失败**：确认已安装 `cmake/ninja/nasm` 且 `VCPKG_ROOT`、`ANDROID_NDK_HOME` 已正确导出；
  网络问题可配置 vcpkg 镜像或代理。
- **`.so` 找不到**：检查 `jniLibs/arm64-v8a/` 下同时存在 `librustdesk.so` 与 `libc++_shared.so`。
- **Gradle 下载慢**：已将仓库源与 Gradle 分发包切换为阿里云镜像（见 `settings.gradle` /
  `build.gradle` / `gradle-wrapper.properties`）。
