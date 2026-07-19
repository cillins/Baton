export const RING_C = 188.5

export const DEVICES = [
  { id: "living",  name: "客厅 Siri Remote", model: "Siri Remote（第 3 代）", batt: 87, connected: true,  last: "当前已连接", art: "gen2" },
  { id: "bedroom", name: "卧室 Siri Remote", model: "Siri Remote（第 2 代）", batt: 18, connected: true,  last: "当前已连接", art: "gen2" },
  { id: "study",   name: "书房 Siri Remote", model: "Siri Remote（第 1 代）", batt: 64, connected: false, last: "3 天前",    art: "gen1" }
]

/* 按键映射按代际区分：
 *   gen2（2/3 代，共用银色 Clickpad 机型）= 7 个可映射按键；
 *     电源为硬件默认行为，不参与映射；音量 ± 为侧边独立按键，可映射为音量或章节跳转。
 *   gen1（1 代，黑色塑料机型）= 6 个可映射按键；
 *     菜单/主页/Siri 是顶面独立按钮，音量 ± 是侧边独立按钮，可映射。 */
export const BUTTON_MAPS = {
  gen2: [
    { key: "侧边按钮（返回）", gesture: "单击", options: ["返回上一级", "打开搜索", "不执行操作"] },
    { key: "电视 / 主页按钮",  gesture: "单击", options: ["打开 TV App", "回到主屏幕", "打开控制中心"] },
    { key: "播放 / 暂停",       gesture: "单击", options: ["播放或暂停", "切换静音", "不执行操作"] },
    { key: "静音按钮",          gesture: "单击", options: ["切换静音", "降低音量", "不执行操作"] },
    { key: "Siri 按钮",         gesture: "按住", options: ["呼出 Siri", "打开搜索", "不执行操作"] },
    { key: "音量 +",            gesture: "单击", options: ["增大音量", "跳到下一章节", "不执行操作"] },
    { key: "音量 -",            gesture: "单击", options: ["减小音量", "跳到上一章节", "不执行操作"] }
  ],
  gen1: [
    { key: "菜单按钮",   gesture: "单击", options: ["返回上一级", "打开搜索", "不执行操作"] },
    { key: "主页按钮",   gesture: "单击", options: ["回到主屏幕", "打开 TV App", "不执行操作"] },
    { key: "播放 / 暂停", gesture: "单击", options: ["播放或暂停", "切换静音", "不执行操作"] },
    { key: "Siri 按钮",  gesture: "长按", options: ["呼出 Siri", "打开搜索", "不执行操作"] },
    { key: "音量 +",     gesture: "单击", options: ["增大音量", "跳到下一章节", "不执行操作"] },
    { key: "音量 -",     gesture: "单击", options: ["减小音量", "跳到上一章节", "不执行操作"] }
  ]
}

/* 触摸板手势映射按代际区分：
 *   gen2（2/3 代）= 8 个手势：四方向轻扫、单击、双指滑动、长按、屏幕边缘滑动；
 *     边缘滑动与双指滑动为 2/3 代硬件独有。
 *   gen1（1 代）= 6 个手势：四方向轻扫、单击、长按；
 *     1 代硬件不支持双指滑动与屏幕边缘滑动。 */
export const TOUCHPAD_MAPS = {
  gen2: [
    { key: "上滑",     desc: "单指向上轻扫",     options: ["向上滚动 / 翻页", "调高音量", "打开控制中心", "不执行操作"] },
    { key: "下滑",     desc: "单指向下轻扫",   options: ["向下滚动 / 翻页", "调低音量", "显示桌面", "不执行操作"] },
    { key: "左滑",     desc: "单指向左轻扫",   options: ["向后切换", "返回上一级", "不执行操作"] },
    { key: "右滑",     desc: "单指向右轻扫",   options: ["向前切换", "回到主屏幕", "不执行操作"] },
    { key: "点击",     desc: "轻点触控板中央", options: ["确认 / 打开", "播放或暂停", "不执行操作"] },
    { key: "双指滑动", desc: "两指同时轻扫",   options: ["滚动 / 缩放", "切换全屏空间", "不执行操作"] },
    { key: "长按",     desc: "按住约 1 秒",     options: ["呼出 Siri", "打开快捷菜单", "不执行操作"] },
    { key: "边缘滑动", desc: "从屏幕边缘滑入", options: ["Mission Control", "通知中心", "控制中心", "不执行操作"] }
  ],
  gen1: [
    { key: "上滑", desc: "单指向上轻扫",     options: ["向上滚动 / 翻页", "调高音量", "不执行操作"] },
    { key: "下滑", desc: "单指向下轻扫",   options: ["向下滚动 / 翻页", "调低音量", "不执行操作"] },
    { key: "左滑", desc: "单指向左轻扫",   options: ["向后切换", "返回上一级", "不执行操作"] },
    { key: "右滑", desc: "单指向右轻扫",   options: ["向前切换", "回到主屏幕", "不执行操作"] },
    { key: "点击", desc: "轻点触控板中央", options: ["确认 / 打开", "播放或暂停", "不执行操作"] },
    { key: "长按", desc: "按住约 1 秒",     options: ["呼出 Siri", "不执行操作"] }
  ]
}

/* 应用预设：前台打开对应应用时自动套用映射模板 */
/* 映射配置（模板）：一套配置 = 完整的按键映射 + 触控板手势映射。
 * btn / tp 按代际保存每行选中项的下标，缺省为 0（第一项即默认行为）。
 * 配置在应用预设中按前台应用自动套用，可新建任意多套自定义配置。 */
export const MAPPING_PROFILES = [
  { id: "default", name: "默认映射", builtin: true, btn: {}, tp: {} },
  { id: "present", name: "演示模式",
    btn: { gen2: [0,1,0,0,0,1,1], gen1: [0,1,0,0,1,1] },
    tp:  { gen2: [0,0,0,0,0,0,1,0], gen1: [0,0,0,0,0,0] } },
  { id: "media", name: "媒体播放",
    btn: { gen2: [0,0,0,1,0,0,0], gen1: [0,0,0,0,0,0] },
    tp:  { gen2: [1,1,0,0,1,0,0,0], gen1: [1,1,0,0,1,0] } },
  { id: "edit", name: "剪辑工作流",
    btn: { gen2: [0,0,0,0,0,1,1], gen1: [0,0,0,0,1,1] },
    tp:  { gen2: [0,0,0,0,0,1,0,2], gen1: [0,0,0,0,0,0] } }
]

export const APP_ICON = {
  present: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M12 16v4M9 21h6"/></svg>',
  play:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M10 8.5l5 3.5-5 3.5z"/></svg>',
  film:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 10h4M3 14h4M17 10h4M17 14h4"/></svg>',
  grid:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/></svg>'
}

export const APP_PRESETS = [
  { app: "Keynote",       icon: "present", tpl: "演示模式" },
  { app: "IINA",          icon: "play",    tpl: "媒体播放" },
  { app: "Final Cut Pro", icon: "film",    tpl: "剪辑工作流" },
  { app: "其他应用",      icon: "grid",    tpl: "默认映射" }
]
