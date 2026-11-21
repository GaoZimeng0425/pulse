# 第三方开源声明

Pulse 每应用音量(app-volume)的音频部分包含或改编了以下 MIT 许可代码
(经 [lishuangqiang/mixbar](https://github.com/lishuangqiang/mixbar) 移植,
取用日期 2026-11-21):

- `Pulse/Live/AppAudioPipeline.swift` — 每应用私有进程 tap + 私有聚合设备 +
  增益渲染(25ms 斜坡、峰值限制器、HFP 单声道下混)改编自 mixbar
  `Sources/Audio/ProcessTap.swift`。
- `Pulse/Live/AppAudioSupport.swift` — CoreAudio 属性读取辅助改编自 mixbar
  `Sources/Audio/CoreAudioSupport.swift`。
- `Pulse/Live/LiveAppVolumeEngine.swift` 的归因部分(宿主 app 匹配、可选
  `responsibility_get_pid_responsible_for_pid` SPI)与
  `Pulse/Features/AppVolumeFeature.swift` 的编排(reconcile 防抖、停摆看门狗、
  睡眠自愈)改编自 mixbar `Sources/Audio/AudioMixer.swift`。
- `Packages/PulseCore/Sources/PulseCore/AppVolumeModel.swift` 的响度曲线
  (滑块位平方)改编自 mixbar `Sources/Audio/VolumeCurve.swift`。

## Mixbar

- 项目:https://github.com/lishuangqiang/mixbar(MIT)
- 原作者:lishuangqiang

```text
MIT License

Copyright (c) 2026 lishuangqiang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

mixbar 自身声明其音频部分改编自下述两个 MIT 项目(Pulse 的移植因此同受其惠):

## Fader

- 项目:https://github.com/pantafive/fader(MIT)
- 参考提交(mixbar 声明):`a6958a4ac341b8826f268752e98d5b79c066ef2c`
- 原作者:pantafive

```text
MIT License

Copyright (c) 2026 pantafive

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MacMixer

- 项目:https://github.com/burghr/MacMixer(MIT)
- 参考提交(mixbar 声明):`3b2c69015949786b02462281420bb6eb75488434`
- 原作者:burghr

```text
MIT License

Copyright (c) 2026 burghr

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
