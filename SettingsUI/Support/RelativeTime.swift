//
//  RelativeTime.swift
//  Baton
//
//  "X 天前" / "X 小时前" / "刚刚" formatter. Lives in support/
//  rather than Theme.swift since it is the only formatting helper.
//

import Foundation

enum RelativeTime {
    static func format(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "未知时间" }
        let sec = max(0, now.timeIntervalSince(date))
        if sec < 60 { return "刚刚" }
        if sec < 3600 {
            return "\(Int(sec / 60)) 分钟前"
        }
        if sec < 86400 {
            return "\(Int(sec / 3600)) 小时前"
        }
        let days = Int(sec / 86400)
        if days < 30 {
            return "\(days) 天前"
        }
        return "很久之前"
    }
}
