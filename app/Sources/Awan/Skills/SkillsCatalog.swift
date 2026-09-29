import Foundation

/// A bundled copy of twelve official skills (server/src/skills-seed.ts — keep slugs, symbols and colours in step)
/// for the pre-sign-in "What should Awan be good at?" picker, which runs before there's an account to fetch with.
enum SkillsCatalog {
    private static func item(_ slug: String, _ title: String, _ oneLiner: String, _ category: String, _ symbol: String, _ inside: [String]) -> SkillItem {
        let colors = ["writing": "#F5C451", "research": "#6FB7FF", "design": "#FF8FB8", "dev": "#57D3C5",
                      "marketing": "#FF9F5A", "productivity": "#7BD88F", "learning": "#B69CFF", "fun": "#FF7A7A"]
        return SkillItem(slug: slug, title: title, oneLiner: oneLiner, whatsInside: inside, category: category,
                         categoryName: category == "dev" ? "Dev" : category.capitalized, symbol: symbol,
                         color: colors[category] ?? "#8B8981", author: "FF Dev Studio", isOfficial: true, published: true, origin: "library")
    }

    static let onboarding: [SkillItem] = [
        item("plain-speaker", "Plain Speaker", "Turns stiff, wordy writing into sentences people actually finish.", "writing", "pencil.line",
             ["Cuts filler and throat-clearing", "Swaps jargon for everyday words", "Keeps the writer’s own voice", "Shows the before and after"]),
        item("reply-drafter", "Reply Drafter", "Drafts the email or message reply you keep putting off, in your tone.", "writing", "arrowshape.turn.up.left.fill",
             ["Reads the thread on screen", "Three tones: warm, firm, brief", "Never sends anything itself", "Types straight into the reply box"]),
        item("bm-santai", "BM Santai", "Writes Bahasa Malaysia the way Malaysians actually talk, not textbook BM.", "writing", "text.bubble.fill",
             ["Colloquial Malaysian BM", "English trade words kept as-is", "No Indonesian spellings", "Captions, WhatsApp and replies"]),
        item("source-checker", "Source Checker", "Asks \"says who?\" about any claim and tells you how much to trust it.", "research", "checkmark.seal.fill",
             ["Finds the original source", "Rates confidence: solid, shaky, unknown", "Spots recycled or AI-written claims", "Links you can check yourself"]),
        item("market-snapshot", "Market Snapshot", "A one-page read on any market: who is in it, what they charge, where the gap is.", "research", "chart.bar.xaxis",
             ["Top players and their pricing", "Who the customers really are", "The gap nobody fills", "Delivered as a sheet or one-pager"]),
        item("ui-critic", "UI Critic", "Looks at any screen and names the three fixes that matter most.", "design", "rectangle.and.hand.point.up.left.fill",
             ["Hierarchy, spacing, contrast checks", "Three fixes, ranked", "Points at each problem", "Taste without the lecture"]),
        item("bug-whisperer", "Bug Whisperer", "Reads the error, finds the real cause and gives you the smallest fix.", "dev", "ladybug.fill",
             ["Reads stack traces calmly", "Finds the cause, not the symptom", "Smallest safe fix", "How to confirm it worked"]),
        item("caption-coach", "Caption Coach", "Writes social captions with a hook, a point and a reason to reply.", "marketing", "camera.fill",
             ["Hook in the first line", "Three options per post", "Platform-aware length", "Hashtags only when they help"]),
        item("daily-planner", "Daily Planner", "Turns a messy to-do list into a realistic plan for today.", "productivity", "calendar",
             ["Picks the one thing that matters", "Time-boxed blocks", "Moves the rest to later", "An honest end-of-day check"]),
        item("meeting-minutes", "Meeting Minutes", "Turns a call transcript or scribbles into decisions, owners and dates.", "productivity", "person.3.fill",
             ["Decisions, not a transcript", "Owner and due date per action", "Open questions listed", "Ready-to-send recap"]),
        item("explain-like-new", "Explain Like I’m New", "Explains anything from scratch with one good analogy and no jargon.", "learning", "lightbulb.fill",
             ["One analogy that fits", "Builds from what you know", "Checks you got it", "Jargon translated"]),
        item("recipe-rescue", "Recipe Rescue", "Tells you what to cook with what is in the fridge right now.", "fun", "fork.knife",
             ["Cooks from what you have", "Swaps for missing items", "Malaysian pantry friendly", "Steps short enough to follow"]),
    ]
}
