import Foundation

struct DailyReadingStat:Identifiable,Hashable,Sendable{var id:String{"\(bookId)-\(epochDay)"};var bookId:Int64;var epochDay:Int64;var durationMs:Int64;var lastReadAt:Int64}
struct HourlyReadingStat:Identifiable,Hashable,Sendable{var id:String{"\(bookId)-\(epochDay)-\(hour)"};var bookId:Int64;var epochDay:Int64;var hour:Int;var durationMs:Int64}
struct NamedReadingStat:Identifiable,Hashable,Sendable{var id:String{name};var name:String;var durationMs:Int64}
struct ReadingStatsSnapshot:Sendable{var totalMs:Int64;var daily:[DailyReadingStat];var hourly:[HourlyReadingStat];var byBook:[Int64:Int64];var byAuthor:[NamedReadingStat];var streakDays:Int;var activeDays:Int}

actor ReadingStatsRepository{
    static let shared=ReadingStatsRepository();private let db=MoReadDatabase.shared
    func snapshot(startEpochDay:Int64?=nil,endEpochDay:Int64?=nil)async throws->ReadingStatsSnapshot{
        var clauses:[String]=[],bind:[SQLValue]=[];if let startEpochDay{clauses.append("epochDay>=?");bind.append(.integer(startEpochDay))};if let endEpochDay{clauses.append("epochDay<=?");bind.append(.integer(endEpochDay))};let whereSQL=clauses.isEmpty ? "":" WHERE "+clauses.joined(separator:" AND ")
        let daily=try await db.rows("SELECT * FROM reading_daily\(whereSQL) ORDER BY epochDay",bind).map{DailyReadingStat(bookId:$0["bookId"]?.int64 ?? 0,epochDay:$0["epochDay"]?.int64 ?? 0,durationMs:$0["durationMs"]?.int64 ?? 0,lastReadAt:$0["lastReadAt"]?.int64 ?? 0)}
        let hourly=try await db.rows("SELECT * FROM reading_hourly\(whereSQL) ORDER BY epochDay,hour",bind).map{HourlyReadingStat(bookId:$0["bookId"]?.int64 ?? 0,epochDay:$0["epochDay"]?.int64 ?? 0,hour:Int($0["hour"]?.int64 ?? 0),durationMs:$0["durationMs"]?.int64 ?? 0)}
        let byBook=Dictionary(grouping:daily,by:\.bookId).mapValues{$0.reduce(Int64(0)){$0+$1.durationMs}}
        let authorRows=try await db.rows("SELECT b.author AS name,SUM(r.durationMs) AS ms FROM reading_daily r JOIN books b ON b.id=r.bookId\(whereSQL.isEmpty ? "" : " WHERE "+clauses.map{"r.\($0)"}.joined(separator:" AND ")) GROUP BY b.author ORDER BY ms DESC",bind)
        let authors=authorRows.map{NamedReadingStat(name:($0["name"]?.string ?? "").isEmpty ? "未知作者":($0["name"]?.string ?? ""),durationMs:$0["ms"]?.int64 ?? 0)}
        let days=Set(daily.filter{$0.durationMs>0}.map(\.epochDay));let today=Self.epochDay(Date());var streak=0; var day=today;while days.contains(day){streak+=1;day-=1}
        return .init(totalMs:daily.reduce(0){$0+$1.durationMs},daily:daily,hourly:hourly,byBook:byBook,byAuthor:authors,streakDays:streak,activeDays:days.count)
    }
    static func epochDay(_ date:Date,calendar: Calendar = .current)->Int64{let c=calendar.dateComponents([.year,.month,.day],from:date);let local=calendar.date(from:c) ?? date;let epoch=calendar.date(from:DateComponents(year:1970,month:1,day:1))!;return Int64(calendar.dateComponents([.day],from:epoch,to:local).day ?? 0)}
}
