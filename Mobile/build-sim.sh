#!/bin/zsh
# 不经过 Xcode 工程，直接用编译器把 iPhone 版编出来、装进模拟器。
#
# 为什么要这样：这台 Mac 的 Xcode 没装 iOS 26.4 的平台组件，xcodebuild 一个 iOS 目标都不肯编；
# 但编译器和模拟器开发包是 Xcode 自带的，旧的 iOS 18.2 模拟器也在，所以绕过 xcodebuild 就能跑。
# 装好平台组件之后，正常用 Xcode 打开工程选 BeanPodMobile 就行，不需要这个脚本。
#
# 用法：Mobile/build-sim.sh            只编译
#       Mobile/build-sim.sh run        编译、装进模拟器并打开
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=arm64-apple-ios18.0-simulator
OUT=build-ios/sim
APP=$OUT/BeanPod.app
DEVICE="${BEANPOD_SIM:-iPhone 16 Pro}"
mkdir -p $OUT $APP

echo "① 协议库 BeanKit"
xcrun swiftc -sdk "$SDK" -target $TARGET -swift-version 6 -parse-as-library -Onone -g \
  -module-name BeanKit -emit-module -emit-module-path $OUT/BeanKit.swiftmodule \
  -emit-library -static -o $OUT/libBeanKit.a Sources/BeanKit/*.swift

echo "② 应用"
xcrun swiftc -sdk "$SDK" -target $TARGET -swift-version 6 -parse-as-library -Onone -g \
  -default-isolation MainActor -module-name BeanPod \
  -I $OUT -L $OUT -lBeanKit \
  Shared/*.swift Mobile/*.swift -o $APP/BeanPod

echo "③ 资源"
rm -f "$APP"/xiaodou_*.png(N)
cp Shared/Assets.xcassets/MiBox.imageset/MiBox.png "$APP/MiBox.png"
# 图标：资源目录要对应版本的模拟器系统才能编，这里直接缩两张图放进去（强调色在代码里另有一份，见 Theme）
sips -z 120 120 Mobile/Assets.xcassets/AppIcon.appiconset/icon_1024.png --out "$APP/AppIcon60x60@2x.png" >/dev/null
sips -z 180 180 Mobile/Assets.xcassets/AppIcon.appiconset/icon_1024.png --out "$APP/AppIcon60x60@3x.png" >/dev/null
/usr/libexec/PlistBuddy -x -c "Print" Mobile/Info.plist > $APP/Info.plist
for kv in "CFBundleExecutable BeanPod" "CFBundleIdentifier com.andyhu.beanpod.mobile" "CFBundleName 密盒助手" \
          "CFBundlePackageType APPL" "CFBundleShortVersionString 0.1.0" "CFBundleVersion 1" "MinimumOSVersion 18.0"; do
  k=${kv%% *}; v=${kv#* }
  /usr/libexec/PlistBuddy -c "Set :$k $v" $APP/Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$k string $v" $APP/Info.plist
done
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" \
  -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" \
  -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName string AppIcon" $APP/Info.plist >/dev/null
codesign -s - --force $APP >/dev/null 2>&1

echo "编好了：$APP"
if [ "$1" = "run" ]; then
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl install "$DEVICE" $APP
  xcrun simctl launch "$DEVICE" com.andyhu.beanpod.mobile
fi
