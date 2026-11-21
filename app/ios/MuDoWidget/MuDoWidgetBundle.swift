import SwiftUI
import WidgetKit

@main
struct MuDoWidgetBundle: WidgetBundle {
    var body: some Widget { MuDoWidget() }
}

struct MuDoWidget: Widget {
    let kind = "dev.steve.MuDoPhone.Widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectServerIntent.self, provider: Provider()) { entry in
            MuDoWidgetView(entry: entry)
        }
        .configurationDisplayName("MuDo")
        .description("The active cswap account and the latest sessions of a server.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
