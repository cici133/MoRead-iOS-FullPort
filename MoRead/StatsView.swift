import SwiftUI
import Charts
import UIKit

enum StatsPeriod: String, CaseIterable, Identifiable { case total="总",year="年",month="月",week="周",day="日";var id:String{rawValue} }

private enum StatsCard: String, CaseIterable, Identifiable {
    case summary = "概览", heatmap = "阅读热力", calendar = "封面月历", timeline = "阅读时间线", hourly = "时段分析", books = "按书统计", authors = "作者"
    var id: String { rawValue }
}

struct StatsView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("stats.visible.cards") private var visibleCardsRaw = StatsCard.allCases.map(\.rawValue).joined(separator: "|")
    @AppStorage("stats.card.order") private var cardOrderRaw = StatsCard.allCases.map(\.rawValue).joined(separator: "|")
    @State private var showCardManager = false
    @State private var period: StatsPeriod = .month
    @State private var anchor = Date()
    @State private var snapshot: ReadingStatsSnapshot?
    @State private var selectedDay: Int64?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("统计周期", selection: $period) { ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    periodNavigation
                    if let s=snapshot {
                        cardGrid(s)
                        if let selectedDay { dayDetail(s, epochDay:selectedDay) }
                    } else { ProgressView("正在读取统计…").padding(.top,40) }
                }.padding()
            }
            .navigationTitle("阅读统计")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { cardMenu } }
            .sheet(isPresented:$showCardManager) { NavigationStack { StatsCardManager(orderRaw:$cardOrderRaw,visibleRaw:$visibleCardsRaw) } }
            .task { await reload() }
            .onChange(of: period) { _,_ in Task { await reload() } }
            .onChange(of: anchor) { _,_ in Task { await reload() } }
            .alert("统计读取失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}} message:{Text(errorText ?? "")}
        }
    }

    private var visibleCards: Set<StatsCard> {
        let names = Set(visibleCardsRaw.split(separator: "|").map(String.init))
        let resolved = Set(StatsCard.allCases.filter { names.contains($0.rawValue) })
        return resolved.isEmpty ? Set(StatsCard.allCases) : resolved
    }

    private var orderedCards: [StatsCard] {
        let parsed = cardOrderRaw.split(separator:"|").compactMap { raw in StatsCard.allCases.first { $0.rawValue == String(raw) } }
        let missing = StatsCard.allCases.filter { !parsed.contains($0) }
        return parsed + missing
    }

    private var cardMenu: some View {
        Menu {
            Section("显示组件") {
                ForEach(StatsCard.allCases) { card in
                    Button { toggle(card) } label: {
                        Label(card.rawValue, systemImage: visibleCards.contains(card) ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Button("调整组件顺序") { showCardManager = true }
            Button("恢复默认") { visibleCardsRaw = StatsCard.allCases.map(\.rawValue).joined(separator: "|"); cardOrderRaw = StatsCard.allCases.map(\.rawValue).joined(separator: "|") }
        } label: { Image(systemName: "rectangle.3.group") }
    }

    private func toggle(_ card: StatsCard) {
        var values = visibleCards
        if values.contains(card) {
            if values.count > 1 { values.remove(card) }
        } else { values.insert(card) }
        visibleCardsRaw = StatsCard.allCases.filter(values.contains).map(\.rawValue).joined(separator: "|")
    }

    private func cardGrid(_ s: ReadingStatsSnapshot) -> some View {
        let columns = horizontalSizeClass == .regular
            ? [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
            : [GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            ForEach(orderedCards.filter { visibleCards.contains($0) }) { card in
                cardView(card, snapshot:s)
            }
        }
    }

    @ViewBuilder private func cardView(_ card: StatsCard, snapshot s: ReadingStatsSnapshot) -> some View {
        switch card {
        case .summary: summary(s)
        case .heatmap: heatmap(s)
        case .calendar: coverCalendar(s)
        case .timeline: timeline(s)
        case .hourly: hourly(s)
        case .books: bookRanking(s)
        case .authors: authorCloud(s)
        }
    }

    private var periodNavigation: some View {
        HStack {
            if period != .total { Button { shift(-1) } label:{Image(systemName:"chevron.left")} }
            Spacer(); Text(periodTitle).font(.headline); Spacer()
            if period != .total { Button { shift(1) } label:{Image(systemName:"chevron.right")} }
        }
    }

    private func summary(_ s:ReadingStatsSnapshot)->some View {
        HStack(spacing:12){metric("阅读时长",duration(s.totalMs),"clock");metric("活跃天数","\(s.activeDays)","calendar");metric("连续阅读","\(s.streakDays) 天","flame")}
    }
    private func metric(_ title:String,_ value:String,_ icon:String)->some View{VStack(spacing:6){Image(systemName:icon).font(.title2);Text(value).font(.headline);Text(title).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding().background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))}

    private func heatmap(_ s: ReadingStatsSnapshot) -> some View {
        let values = Dictionary(grouping: s.daily, by: \.epochDay)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.durationMs } }
        let days = heatmapDays
        return VStack(alignment: .leading, spacing: 10) {
            Text("阅读热力").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(days, id: \.self) { day in
                    heatmapCell(day: day, value: values[day] ?? 0)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func heatmapCell(day: Int64, value: Int64) -> some View {
        let opacity = value == 0 ? 0.06 : min(0.85, 0.12 + Double(value) / 7_200_000)
        let foreground = value > 1_800_000 ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary)
        return Button {
            selectedDay = day
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(.primary.opacity(opacity))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(dayLabel(day))
                        .font(.system(size: 8))
                        .foregroundStyle(foreground)
                }
        }
        .buttonStyle(.plain)
    }

    private func coverCalendar(_ s: ReadingStatsSnapshot) -> some View {
        let calendar = Calendar.current
        let monthDate = anchor
        let interval = calendar.dateInterval(of: .month, for: monthDate)
        let start = interval?.start ?? monthDate
        let range = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<2
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days: [Int64?] = Array(repeating:nil,count:leading) + range.map { day -> Int64? in
            guard let date = calendar.date(byAdding:.day,value:day-1,to:start) else{return nil}
            return ReadingStatsRepository.epochDay(date)
        }
        let dailyByDay = Dictionary(grouping:s.daily,by:\.epochDay)
        return VStack(alignment:.leading,spacing:10) {
            HStack { Text("封面月历").font(.headline); Spacer(); Text(start.formatted(.dateTime.year().month())).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:4) { ForEach(calendar.veryShortWeekdaySymbols,id:\.self){Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity)} }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:5),count:7),spacing:5) {
                ForEach(Array(days.enumerated()),id:\.offset){_,value in
                    if let day=value {
                        let rows=dailyByDay[day].orEmpty
                        let primary=rows.max{$0.durationMs<$1.durationMs}
                        let total=rows.reduce(Int64(0)){$0+$1.durationMs}
                        Button { selectedDay=day } label: {
                            ZStack(alignment:.topLeading) {
                                RoundedRectangle(cornerRadius:8).fill(.primary.opacity(0.045))
                                if let bookId=primary?.bookId,let path=store.books.first(where:{$0.id==bookId})?.coverPath,
                                   let image=UIImage(contentsOfFile:path) {
                                    Image(uiImage:image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius:8)).opacity(0.78)
                                }
                                LinearGradient(colors:[.black.opacity(0.52),.clear,.black.opacity(0.42)],startPoint:.top,endPoint:.bottom).clipShape(RoundedRectangle(cornerRadius:8))
                                Text(dayLabel(day)).font(.caption.bold()).foregroundStyle(.white).padding(5)
                                if total>0 { Text(shortDuration(total)).font(.system(size:8,weight:.semibold)).foregroundStyle(.white).padding(5).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing) }
                            }.aspectRatio(0.72,contentMode:.fit)
                        }.buttonStyle(.plain)
                    } else { Color.clear.aspectRatio(0.72,contentMode:.fit) }
                }
            }
            Text("每天使用阅读时长最高的书作为主封面；点击日期查看当天全部记录。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }

    private func timeline(_ s:ReadingStatsSnapshot)->some View {
        VStack(alignment:.leading){Text("阅读时间线").font(.headline);Chart(aggregateDaily(s)){item in BarMark(x:.value("日期",date(for:item.epochDay)),y:.value("分钟",Double(item.durationMs)/60000)).cornerRadius(3)}.frame(height:180)}.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
    private func hourly(_ s:ReadingStatsSnapshot)->some View {
        let hours=Dictionary(grouping:s.hourly,by:\.hour).mapValues{$0.reduce(Int64(0)){$0+$1.durationMs}}
        return VStack(alignment:.leading){Text("时段分析").font(.headline);Chart(0..<24,id:\.self){h in BarMark(x:.value("小时",h),y:.value("分钟",Double(hours[h] ?? 0)/60000))}.frame(height:160)}.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
    private func bookRanking(_ s:ReadingStatsSnapshot)->some View {
        VStack(alignment:.leading,spacing:11){
            Text("按书统计").font(.headline)
            ForEach(s.byBook.sorted{$0.value>$1.value}.prefix(10),id:\.key){id,ms in
                VStack(alignment:.leading,spacing:3){
                    HStack{Text(store.books.first{$0.id==id}?.title ?? "已移除书籍").lineLimit(1);Spacer();Text(duration(ms)).foregroundStyle(.secondary)}
                    let streak=bookStreak(bookId:id,snapshot:s)
                    if streak.days > 0 { Text("连续阅读 \(streak.days) 天 · \(streak.label)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
    private func authorCloud(_ s:ReadingStatsSnapshot)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text("作者词云").font(.headline)
            PackedStatsCloud(items: Array(s.byAuthor.prefix(48)))
                .frame(height: 230)
            if s.byAuthor.count > 48 {
                DisclosureGroup("其余 \(s.byAuthor.count - 48) 位作者") {
                    ForEach(Array(s.byAuthor.dropFirst(48).prefix(80))) { a in
                        HStack { Text(a.name); Spacer(); Text(duration(a.durationMs)).foregroundStyle(.secondary) }
                            .font(.caption)
                    }
                }
            }
        }.padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))
    }
    private func dayDetail(_ s: ReadingStatsSnapshot, epochDay: Int64) -> some View {
        let rows = s.daily.filter { $0.epochDay == epochDay }.sorted { $0.durationMs > $1.durationMs }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当天完整记录 · \(date(for: epochDay).formatted(date: .abbreviated, time: .omitted))")
                    .font(.headline)
                Spacer()
                Button { selectedDay = nil } label: { Image(systemName: "xmark.circle.fill") }
            }
            ForEach(rows) { row in
                VStack(alignment:.leading,spacing:3) {
                    HStack {
                        Text(store.books.first { $0.id == row.bookId }?.title ?? "已移除书籍")
                        Spacer()
                        Text(duration(row.durationMs)).foregroundStyle(.secondary)
                    }
                    let hours=s.hourly.filter{$0.epochDay==epochDay && $0.bookId==row.bookId && $0.durationMs>0}.sorted{$0.hour<$1.hour}
                    if !hours.isEmpty {
                        Text(hours.map{"\(String(format:"%02d",$0.hour)):00 \(duration($0.durationMs))"}.joined(separator:" · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if row.lastReadAt > 0 { Text("最后记录 \(Date(timeIntervalSince1970:Double(row.lastReadAt)/1000).formatted(date:.omitted,time:.shortened))").font(.caption2).foregroundStyle(.tertiary) }
                }
                if row.id != rows.last?.id { Divider() }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func bookStreak(bookId:Int64,snapshot:ReadingStatsSnapshot)->(days:Int,label:String) {
        let days=Array(Set(snapshot.daily.filter{$0.bookId==bookId && $0.durationMs>0}.map(\.epochDay))).sorted()
        guard let first=days.first else{return(0,"")}
        var bestStart=first,bestEnd=first,currentStart=first,previous=first
        for day in days.dropFirst() {
            if day==previous+1 { previous=day }
            else {
                if previous-currentStart > bestEnd-bestStart { bestStart=currentStart;bestEnd=previous }
                currentStart=day;previous=day
            }
        }
        if previous-currentStart > bestEnd-bestStart { bestStart=currentStart;bestEnd=previous }
        let count=Int(bestEnd-bestStart+1)
        let label = bestStart==bestEnd ? date(for:bestStart).formatted(.dateTime.month().day()) : "\(date(for:bestStart).formatted(.dateTime.month().day()))–\(date(for:bestEnd).formatted(.dateTime.month().day()))"
        return(count,label)
    }
    private func shortDuration(_ ms:Int64)->String{let minutes=max(0,ms/60000);return minutes>=60 ? "\(minutes/60)h\(minutes%60)m" : "\(minutes)m"}

    @MainActor private func reload() async { do { let b=bounds; snapshot=try await ReadingStatsRepository.shared.snapshot(startEpochDay:b?.0,endEpochDay:b?.1) } catch { errorText=error.localizedDescription } }
    private var bounds:(Int64,Int64)?{guard period != .total else{return nil};let cal=Calendar.current;let interval:DateInterval?=switch period{case .year:cal.dateInterval(of:.year,for:anchor);case .month:cal.dateInterval(of:.month,for:anchor);case .week:cal.dateInterval(of:.weekOfYear,for:anchor);case .day:cal.dateInterval(of:.day,for:anchor);case .total:nil};guard let interval else{return nil};return (ReadingStatsRepository.epochDay(interval.start),ReadingStatsRepository.epochDay(interval.end.addingTimeInterval(-1)))}
    private var periodTitle:String{switch period{case .total:"全部记录";case .year:anchor.formatted(.dateTime.year());case .month:anchor.formatted(.dateTime.year().month());case .week:"\(Calendar.current.dateInterval(of:.weekOfYear,for:anchor)?.start.formatted(date:.abbreviated,time:.omitted) ?? "") 起";case .day:anchor.formatted(date:.long,time:.omitted)}}
    private func shift(_ delta:Int){let c=Calendar.current;anchor=switch period{case .year:c.date(byAdding:.year,value:delta,to:anchor) ?? anchor;case .month:c.date(byAdding:.month,value:delta,to:anchor) ?? anchor;case .week:c.date(byAdding:.weekOfYear,value:delta,to:anchor) ?? anchor;case .day:c.date(byAdding:.day,value:delta,to:anchor) ?? anchor;case .total:anchor}}
    private var heatmapDays:[Int64]{if let b=bounds{return Array(Array(b.0...b.1).suffix(98))};let today=ReadingStatsRepository.epochDay(Date());return Array((today-97)...today)}
    private func dayLabel(_ day:Int64)->String{String(Calendar.current.component(.day,from:date(for:day)))}
    private func date(for day:Int64)->Date{let e=Calendar.current.date(from:DateComponents(year:1970,month:1,day:1))!;return Calendar.current.date(byAdding:.day,value:Int(day),to:e) ?? e}
    private func aggregateDaily(_ s:ReadingStatsSnapshot)->[DailyReadingStat]{Dictionary(grouping:s.daily,by:\.epochDay).map{day,items in .init(bookId:0,epochDay:day,durationMs:items.reduce(0){$0+$1.durationMs},lastReadAt:items.map(\.lastReadAt).max() ?? 0)}.sorted{$0.epochDay<$1.epochDay}}
    private func duration(_ ms:Int64)->String{let min=ms/60000;if min<60{return "\(min) 分"};return String(format:"%.1f 小时",Double(min)/60)}
}

private struct StatsCardManager: View {
    @Binding var orderRaw: String
    @Binding var visibleRaw: String
    @Environment(\.dismiss) private var dismiss
    @State private var order: [StatsCard]
    @State private var visible: Set<StatsCard>

    init(orderRaw: Binding<String>, visibleRaw: Binding<String>) {
        _orderRaw = orderRaw; _visibleRaw = visibleRaw
        let parsed = orderRaw.wrappedValue.split(separator:"|").compactMap { raw in StatsCard.allCases.first { $0.rawValue == String(raw) } }
        _order = State(initialValue: parsed + StatsCard.allCases.filter { !parsed.contains($0) })
        let names = Set(visibleRaw.wrappedValue.split(separator:"|").map(String.init))
        let selected = Set(StatsCard.allCases.filter { names.contains($0.rawValue) })
        _visible = State(initialValue: selected.isEmpty ? Set(StatsCard.allCases) : selected)
    }

    var body: some View {
        List {
            Section("拖拽调整顺序") {
                ForEach(order) { card in
                    Toggle(isOn:Binding(get:{visible.contains(card)},set:{enabled in if enabled{visible.insert(card)}else if visible.count>1{visible.remove(card)};persist()})) {
                        Label(card.rawValue,systemImage:"line.3.horizontal")
                    }
                }.onMove { indices,destination in order.move(fromOffsets:indices,toOffset:destination);persist() }
            }
            Section { Text("至少保留一个组件；排序和显示状态会在下次打开统计页时继续使用。") .font(.footnote).foregroundStyle(.secondary) }
        }
        .environment(\.editMode,.constant(.active))
        .navigationTitle("统计组件")
        .toolbar { ToolbarItem(placement:.confirmationAction){Button("完成"){persist();dismiss()}} }
    }
    private func persist() {
        orderRaw=order.map(\.rawValue).joined(separator:"|")
        visibleRaw=order.filter { visible.contains($0) }.map(\.rawValue).joined(separator:"|")
    }
}

private struct FlowLayout:Layout{var spacing:CGFloat=8;func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize{let width=proposal.width ?? 320;var x:CGFloat=0,y:CGFloat=0,row:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>width && x>0{x=0;y+=row+spacing;row=0};x+=s.width+spacing;row=max(row,s.height)};return .init(width:width,height:y+row)};func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout()){var x=bounds.minX,y=bounds.minY,row:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>bounds.maxX && x>bounds.minX{x=bounds.minX;y+=row+spacing;row=0};v.place(at:.init(x:x,y:y),anchor:.topLeading,proposal:.init(s));x+=s.width+spacing;row=max(row,s.height)}}}


private struct StatsCloudPlacement: Identifiable {
    let id = UUID()
    let name: String
    let durationMs: Int64
    let point: CGPoint
    let fontSize: CGFloat
    let rotation: Angle
}

private struct PackedStatsCloud: View {
    let items: [NamedReadingStat]
    @State private var overflow: [NamedReadingStat] = []

    var body: some View {
        GeometryReader { proxy in
            let result = StatsCloudLayoutEngine.layout(items: items, size: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(result.placements) { placement in
                    Text(placement.name)
                        .font(.system(size: placement.fontSize, weight: placement.fontSize > 25 ? .semibold : .regular))
                        .rotationEffect(placement.rotation)
                        .position(placement.point)
                        .accessibilityLabel("\\(placement.name)，\\(formatDuration(placement.durationMs))")
                }
                if !result.overflow.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Spacer()
                        Text("+\\(result.overflow.count)").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let minutes = max(0, ms / 60_000)
        return minutes >= 60 ? "\\(minutes / 60) 小时 \\(minutes % 60) 分" : "\\(minutes) 分钟"
    }
}

private enum StatsCloudLayoutEngine {
    struct Result { var placements: [StatsCloudPlacement]; var overflow: [NamedReadingStat] }

    static func layout(items: [NamedReadingStat], size: CGSize) -> Result {
        guard size.width > 80, size.height > 80, !items.isEmpty else { return .init(placements: [], overflow: items) }
        let ordered = items.sorted { lhs, rhs in lhs.durationMs == rhs.durationMs ? lhs.name < rhs.name : lhs.durationMs > rhs.durationMs }
        let maxWeight = Double(max(1, ordered.first?.durationMs ?? 1))
        let minWeight = Double(max(1, ordered.last?.durationMs ?? 1))
        var rects: [CGRect] = []
        var placements: [StatsCloudPlacement] = []
        var overflow: [NamedReadingStat] = []
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)

        for (index, item) in ordered.enumerated() {
            let value = Double(max(1, item.durationMs))
            let ratio = maxWeight == minWeight ? 0.5 : (log(value) - log(minWeight)) / max(0.0001, log(maxWeight) - log(minWeight))
            let font = CGFloat(13 + ratio * 23)
            let rotated = stableHash(item.name) % 7 == 0
            let measured = (item.name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: font, weight: font > 25 ? .semibold : .regular)])
            let itemSize = rotated ? CGSize(width: measured.height + 8, height: measured.width + 8) : CGSize(width: measured.width + 8, height: measured.height + 8)
            var found: CGPoint?
            let phase = CGFloat((stableHash(item.name) % 360)) * .pi / 180
            for step in 0..<900 {
                let t = CGFloat(step) * 0.27 + phase
                let radius = CGFloat(step) * 0.42
                let p = CGPoint(x: center.x + cos(t) * radius, y: center.y + sin(t) * radius * 0.72)
                let r = CGRect(x: p.x - itemSize.width / 2, y: p.y - itemSize.height / 2, width: itemSize.width, height: itemSize.height)
                if bounds.contains(r), rects.allSatisfy({ !$0.insetBy(dx: -2, dy: -2).intersects(r) }) { found = p; rects.append(r); break }
            }
            if let point = found {
                placements.append(.init(name: item.name, durationMs: item.durationMs, point: point, fontSize: font, rotation: rotated ? .degrees(index.isMultiple(of: 2) ? -90 : 90) : .zero))
            } else { overflow.append(item) }
        }
        return .init(placements: placements, overflow: overflow)
    }

    private static func stableHash(_ text: String) -> Int {
        text.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) } & 0x7fffffff
    }
}


private extension Optional where Wrapped == [DailyReadingStat] { var orEmpty:[DailyReadingStat]{ self ?? [] } }
