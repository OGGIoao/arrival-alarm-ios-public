# 构建与实测

## 模拟器

用带 iOS 26 SDK 的 Xcode 打开 [工程](../ArrivalAlarm.xcodeproj)，选 `ArrivalAlarm` scheme 和一个 iPhone 模拟器。默认地点搜索使用 MapKit，无需设置地图服务 Key。

从仓库根目录运行下面的命令，验证到站判定。

```sh
mkdir -p build
xcrun swiftc ArrivalAlarm/ArrivalCheck.swift Tests/ArrivalCheckRegression.swift -o build/arrival-check
./build/arrival-check
```

## 真机安装

1. 在 [App.xcconfig](../Config/App.xcconfig) 中把 `ARRIVAL_APP_BUNDLE_IDENTIFIER` 改成开发团队可用的标识。分享扩展、控件和 App Group 标识会从它派生。
2. 在 Xcode 的 **Signing & Capabilities** 中，为 `ArrivalAlarm`、`ArrivalShare`、`ArrivalWidgets` 选择同一开发团队。主 App 和分享扩展需要使用同一个 App Group。 [Xcode 运行指南](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [App Groups 配置](https://developer.apple.com/documentation/xcode/configuring-app-groups)
3. 用 **Debug** 构建运行到 iPhone。安装后可停止 Xcode 调试，再从 iPhone 主屏幕打开 App。右上角「更多」中可找到「定位诊断」。

## 锁屏提醒和地铁测试

1. 先从「检查提醒」确认精确位置和锁屏通知已经打开，发送测试提醒后锁屏，等 10 秒。测试声音时请开启系统的通知声音。
2. 先在地面选一站和 300 米提醒范围，从圈外开始守候，锁屏走进圈内。确认能收到到站通知，再带着相同的权限和通知设置跑地下线路。
3. 跑一趟熟悉的地下线路。在范围外点「开始守候」后锁屏。记录前一站和目标站的开门时间，观察首次到站通知是否早于目标站开门。
4. 解锁后从「更多」打开「定位诊断」。确认本轮定位已启动且记录完整，再看目标站附近的记录。没有回调，说明 App 在这段时间没有收到位置。有回调就可以看距离和过滤原因。「通知已受理」表示系统收到了请求，可以对照当时的锁屏画面确认是否出现。

开始下一趟守候会替换上一趟诊断，可先从诊断页保存本轮文本。反馈问题时，带上设备型号、iOS 版本、提醒范围、锁屏情况和诊断中的相关时间段。分享截图前请遮住地址和个人行程。
