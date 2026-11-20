# 构建与实测

当前进度以 [README 的阶段说明](../README.md#做到哪一步了) 为准。真机签名安装与启动验收仍未完成，安装成功后再按本页步骤锁屏跑地铁。模拟器通知不能证明地下线路不会漏报。

## 模拟器

用带 iOS 26 SDK 的 Xcode 打开 [工程](../ArrivalAlarm.xcodeproj)，选 `ArrivalAlarm` scheme 和一个 iPhone 模拟器。默认地点搜索使用 MapKit，无需设置地图服务 Key。

从仓库根目录运行下面的命令，验证到站判定和常用地点。

```sh
mkdir -p build
xcrun swiftc ArrivalAlarm/ArrivalCheck.swift Tests/ArrivalCheckRegression.swift -o build/arrival-check
./build/arrival-check
xcrun swiftc ArrivalAlarm/ArrivalCheck.swift ArrivalAlarm/StationSelection.swift Tests/FrequentPlacesRegression.swift -o build/frequent-places
./build/frequent-places
```

到站通知的回归用到了 iOS 的位置通知触发器。在 Apple Silicon Mac 上启动 iPhone 模拟器后，运行下面的命令。多个模拟器同时运行时，把 `booted` 换成要用的设备 UDID。

```sh
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator \
  ArrivalAlarm/ArrivalCheck.swift ArrivalAlarm/StationSelection.swift \
  ArrivalAlarm/ArrivalNotifications.swift Tests/ArrivalNotificationRegression.swift \
  -o build/arrival-notification
xcrun simctl spawn booted "$PWD/build/arrival-notification"
```

## 真机安装

先确认 Xcode 支持手机正在使用的 iOS 版本，参考 [Apple 的版本兼容表](https://developer.apple.com/xcode/system-requirements)。只满足项目最低 iOS 26 要求，不代表旧 Xcode 就能调试更高系统版本的手机。必要时升级开发环境，或使用另一台满足要求的 Mac。

1. 在 [App.xcconfig](../Config/App.xcconfig) 中把 `ARRIVAL_APP_BUNDLE_IDENTIFIER` 改成开发团队可用的标识。分享扩展、控件和 App Group 标识会从它派生。
2. 在 Xcode 的 **Signing & Capabilities** 中，为 `ArrivalAlarm`、`ArrivalShare`、`ArrivalWidgets` 选择同一开发团队。主 App 和分享扩展需要使用同一个 App Group。 [Xcode 运行指南](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [App Groups 配置](https://developer.apple.com/documentation/xcode/configuring-app-groups)
3. 用 **Debug** 构建运行到 iPhone。安装后可停止 Xcode 调试，再从 iPhone 主屏幕打开 App。右上角「设置」中可找到「定位诊断（调试版）」。

默认工程包含“时效性通知”权限。免费个人团队可能在签名时收到 Xcode 的“不支持 Time Sensitive Notifications”提示；这不是 Swift 编译错误。完整配置需要使用支持该权限的开发团队。普通通知的本机试用构建需单独移除该权限，并单独核对通知行为；仓库目前没有提供一键降级配置，不能把待重签的 IPA 当成可安装发布包。

## 锁屏提醒和地铁测试

1. 从首页右上角「设置」→「试一下提醒」，确认精确位置和锁屏通知已经打开，发送测试提醒后锁屏，等 10 秒。测试声音时请开启系统的通知声音。
2. 先在地面选一站和 300 米提醒范围，从圈外开始守候，锁屏走进圈内。确认能收到到站通知，再带着相同的权限和通知设置跑地下线路。
3. 跑一趟熟悉的地下线路。在范围外点「开始守候」后锁屏。记录前一站和目标站的开门时间，观察首次到站通知是否早于目标站开门。
4. 解锁后从「设置」打开「定位诊断（调试版）」。确认本轮定位已启动且记录完整，再看目标站附近的记录。没有回调，说明 App 在这段时间没有收到位置。有回调就可以看距离和过滤原因。「通知已受理」表示系统收到了请求，可以对照当时的锁屏画面确认是否出现。

开始下一趟守候会替换上一趟诊断，可先从诊断页保存本轮文本。反馈问题时，带上设备型号、iOS 版本、提醒范围、锁屏情况和诊断中的相关时间段。分享截图前请遮住地址和个人行程。

真机实测要分别记录：是否出现通知、是否发声或振动、首次提醒时间、是否重复提醒。定位诊断中的「通知已受理」仅证明系统收到了通知请求。地下漏报、静音提醒和耗电情况尚待实测；AlarmKit 尚未接入，不能用普通通知的结果代替它的验证。

## 从锁屏通知接到步行

1. 给最终目的地选择一个不同的下车站。锁屏模拟进圈后点通知正文，核对详情同时显示站名和原目的地，点「步行到目的地」核对地图收到的是原目的地。
2. 另跑一趟，等到站通知实际显示后再终止 App 进程。点仍在通知中心的通知，检查冷启动能否打开这趟的详情。
3. 同一趟的多条通知应指向同一份详情。用旧行程 ID 的测试通知检查失效提示，再核对正在守候的任务。真实旧通知可能已经被 App 清理。
4. 回访测试要先离开再进入提醒范围。升级前登记的回访可能仍能投递，详情需要新建立的回访记录。重新完成一次守候后，再测回访详情和步行交接。

## 首页与 Apple Watch

首次进入时，首页显示地铁插画、搜索入口和一句用途说明。选过地点后，首页显示真实历史。确认地图范围后进入「本次提醒」，开启后回首页应优先看到当前任务。结束后，当前任务卡收起，历史仍可复用。

布局验收时，分别查看首次进入、最近地点、待开始和守候中：标题与插画融合，搜索与卡片之间留有间距，长站名可以换行，底部主按钮不遮挡正文。地图页需同时检查“搜索后确认”和“详情内调整范围”两种入口；地图高度随可用空间调整，大字体或小屏可滚动查看全部说明。

在配对 iPhone 上开启实时活动后，检查 Apple Watch 的智能叠放。打开「锁屏显示站名」时，手表应显示站名和状态，位置可用时再显示直线距离。关闭这项隐私设置后，站名隐藏。分别观察等待定位、位置过期、恢复更新和结束后的卡片呈现，记录真机同步延迟。手表通知与振动需要用配对真机单独核对。
