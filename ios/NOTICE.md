# 澄音 MusicDL 原生 iOS 客户端

基于 guohuiyuan/go-music-dl，源码及原许可证：
https://github.com/guohuiyuan/go-music-dl

本改造源码： https://github.com/yann359/go-music-dl
许可证：GNU AGPL v3，完整文本随 App 附带 LICENSE。
发布 IPA 时同时提供对应提交的完整源码、构建脚本和第三方依赖声明。
保留网页中原有第三方许可文件，不移除任何署名。

仅使用有权访问的音源及账号授权。不绕过付费、DRM、地区限制或平台授权。
换源失败不构成对任何音乐的授权。无损文件保留原始字节；设备是否可解码需实测。

主要界面使用原生 SwiftUI；iOS 26+ 使用系统 Liquid Glass，不使用网页 CSS 模拟。
原项目网页/Android 与音乐核心代码保留，原生客户端通过进程内接口复用音乐能力。
尚未通过真机 30 分钟与连续三首真实歌曲验收。模拟器和界面样例不构成真机通过证据。
