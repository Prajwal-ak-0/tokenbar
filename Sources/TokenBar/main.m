#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "TBUsageModels.h"
#import "TBUsageServices.h"

static NSColor *TBAccentColor(void) {
    return [NSColor colorWithSRGBRed:0.18 green:0.55 blue:0.38 alpha:1.0];
}

static NSTextField *TBLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = NSColor.labelColor;
    return label;
}

static NSBox *TBSeparator(void) {
    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    return separator;
}

@interface TBProgressView : NSView
@property(nonatomic) double value;
@property(nonatomic) NSColor *barColor;
@end


@implementation TBProgressView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect trackRect = NSInsetRect(self.bounds, 0, 1);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:trackRect xRadius:2.5 yRadius:2.5];
    [NSColor.quaternaryLabelColor setFill];
    [track fill];

    CGFloat width = trackRect.size.width * MIN(MAX(self.value, 0), 100) / 100.0;
    if (width <= 0) return;
    NSRect fillRect = NSMakeRect(trackRect.origin.x, trackRect.origin.y, width, trackRect.size.height);
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:2.5 yRadius:2.5];
    [(self.barColor ?: TBAccentColor()) setFill];
    [fill fill];
}

@end

static const CGFloat TBPanelWidth = 344;

static NSColor *TBProviderColor(BOOL claude) {
    return claude ? [NSColor colorWithSRGBRed:0.83 green:0.48 blue:0.35 alpha:1]
                  : [NSColor colorWithSRGBRed:0.37 green:0.59 blue:0.88 alpha:1];
}

static NSString *TBPercent(double percent) {
    double value = MIN(MAX(percent, 0), 100);
    if (value > 0 && value < 0.1) return @"<0.1%";
    return fabs(value - round(value)) < 0.05
        ? [NSString stringWithFormat:@"%.0f%%", value]
        : [NSString stringWithFormat:@"%.1f%%", value];
}

static NSString *TBDuration(NSTimeInterval seconds) {
    NSInteger minutes = MAX(1, (NSInteger)ceil(seconds / 60));
    if (minutes >= 24 * 60) return [NSString stringWithFormat:@"%ldd %ldh", (long)(minutes / 1440), (long)(minutes % 1440 / 60)];
    if (minutes >= 60) return [NSString stringWithFormat:@"%ldh %ldm", (long)(minutes / 60), (long)(minutes % 60)];
    return [NSString stringWithFormat:@"%ldm", (long)minutes];
}

static NSString *TBCaptureAge(NSDate *date) {
    NSTimeInterval age = MAX(0, -date.timeIntervalSinceNow);
    if (age < 60) return @"Just now";
    return [TBDuration(floor(age / 60) * 60) stringByAppendingString:@" ago"];
}

static NSStackView *TBStack(NSArray<NSView *> *views, BOOL vertical, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

static NSView *TBSpacer(void) {
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return spacer;
}

static NSButton *TBSymbolButton(NSString *symbol, NSString *label, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label]
                                       target:target action:action];
    button.bordered = NO;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = label;
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:24].active = YES;
    return button;
}

@interface TBTokenBarViewController : NSViewController
@property(nonatomic, copy) dispatch_block_t onRefresh;
@property(nonatomic, copy) dispatch_block_t onConnectClaude;
@property(nonatomic, copy) dispatch_block_t onAuthorizeClaude;
@property(nonatomic, nullable) TBProviderSnapshot *codexSnapshot;
@property(nonatomic, nullable) TBProviderSnapshot *claudeSnapshot;
@property(nonatomic, nullable, copy) NSString *codexError;
@property(nonatomic, nullable, copy) NSString *claudeError;
@property(nonatomic) BOOL codexLoading;
@property(nonatomic) BOOL claudeLoading;
@property(nonatomic) BOOL claudeNeedsConnection;
@property(nonatomic) BOOL claudeNeedsAuthorization;
@property(nonatomic) BOOL connectingClaude;
@property(nonatomic) BOOL modelLimitsExpanded;
@property(nonatomic, nullable) NSDate *lastUpdated;
@property(nonatomic, nullable) NSDate *nextAutomaticRefreshAt;
@property(nonatomic) NSButton *refreshButton;
@property(nonatomic) NSStackView *contentStack;
@property(nonatomic) NSStackView *outerStack;
@property(nonatomic) NSTextField *settingsMessageLabel;
@property(nonatomic) NSTextField *scheduleLabel;
- (void)render;
@end

@implementation TBTokenBarViewController

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, TBPanelWidth, 360)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    self.view = root;

    self.contentStack = TBStack(@[], YES, 16);
    self.contentStack.edgeInsets = NSEdgeInsetsMake(4, 0, 4, 0);
    self.settingsMessageLabel = TBLabel(@"", 11, NSFontWeightRegular);
    self.settingsMessageLabel.textColor = NSColor.secondaryLabelColor;
    self.settingsMessageLabel.maximumNumberOfLines = 3;
    self.settingsMessageLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.settingsMessageLabel.hidden = YES;

    self.outerStack = TBStack(@[[self headerView], self.contentStack, self.settingsMessageLabel,
                                TBSeparator(), [self footerView]], YES, 12);
    self.outerStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.outerStack.edgeInsets = NSEdgeInsetsMake(14, 16, 12, 16);
    [root addSubview:self.outerStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.outerStack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.outerStack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.outerStack.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.outerStack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    for (NSView *child in self.outerStack.arrangedSubviews) {
        [child.widthAnchor constraintEqualToAnchor:self.outerStack.widthAnchor constant:-32].active = YES;
    }
    [self render];
}

- (NSView *)headerView {
    NSTextField *title = TBLabel(@"TokenBar", 13, NSFontWeightSemibold);
    self.refreshButton = TBSymbolButton(@"arrow.clockwise", @"Refresh usage", self, @selector(refreshPressed:));
    NSButton *settings = TBSymbolButton(@"gearshape", @"TokenBar settings", self, @selector(settingsPressed:));
    return TBStack(@[title, TBSpacer(), self.refreshButton, settings], NO, 6);
}

- (NSView *)footerView {
    NSImageView *clock = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"clock"
                                                                    accessibilityDescription:@"Refresh schedule"]];
    clock.contentTintColor = NSColor.tertiaryLabelColor;
    [clock.widthAnchor constraintEqualToConstant:11].active = YES;
    [clock.heightAnchor constraintEqualToConstant:11].active = YES;
    self.scheduleLabel = TBLabel(@"Checking usage…", 10, NSFontWeightRegular);
    self.scheduleLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *usage = [NSButton buttonWithTitle:@"Usage" target:self action:@selector(openClaudeUsage:)];
    usage.bordered = NO;
    usage.font = [NSFont systemFontOfSize:10];
    usage.contentTintColor = NSColor.secondaryLabelColor;
    usage.image = [NSImage imageWithSystemSymbolName:@"arrow.up.right" accessibilityDescription:nil];
    usage.imagePosition = NSImageRight;
    usage.imageScaling = NSImageScaleProportionallyDown;
    usage.toolTip = @"Open Claude’s usage dashboard";
    return TBStack(@[clock, self.scheduleLabel, TBSpacer(), usage], NO, 5);
}

- (void)render {
    if (!self.viewLoaded) return;
    for (NSView *view in self.contentStack.arrangedSubviews.copy) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray *sections = @[
        [self providerViewWithTitle:@"Codex" snapshot:self.codexSnapshot error:self.codexError loading:self.codexLoading],
        TBSeparator(),
        [self providerViewWithTitle:@"Claude" snapshot:self.claudeSnapshot error:self.claudeError loading:self.claudeLoading],
    ];
    for (NSView *view in sections) {
        [self.contentStack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:self.contentStack.widthAnchor].active = YES;
    }
    BOOL loading = self.codexLoading || self.claudeLoading;
    self.refreshButton.enabled = !loading && !self.connectingClaude;
    NSDate *next = self.nextAutomaticRefreshAt ?: self.claudeSnapshot.nextRefreshAt;
    self.scheduleLabel.stringValue = loading ? @"Checking usage…" :
        next && next.timeIntervalSinceNow > 0
            ? [@"Next check in " stringByAppendingString:TBDuration(next.timeIntervalSinceNow)]
            : @"Automatic refresh";
    self.scheduleLabel.toolTip = @"Claude checks are spaced at least 5 minutes apart. Checks slow down while idle and respect provider cooldowns.";
    [self.view layoutSubtreeIfNeeded];
    CGFloat height = MAX(220, ceil(self.outerStack.fittingSize.height));
    self.preferredContentSize = NSMakeSize(TBPanelWidth, height);
    [self.view setFrameSize:self.preferredContentSize];
    if ([self.view.window.title isEqualToString:@"TokenBar Preview"]) {
        [self.view.window setContentSize:self.preferredContentSize];
    }
}

- (NSView *)providerViewWithTitle:(NSString *)title snapshot:(TBProviderSnapshot *)snapshot
                            error:(NSString *)error loading:(BOOL)loading {
    BOOL claude = [title isEqualToString:@"Claude"];
    NSColor *accent = TBProviderColor(claude);
    NSString *iconName = claude ? @"ProviderIcon-claude" : @"ProviderIcon-codex";
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:iconName ofType:@"svg"]];
    image.template = YES;
    NSImageView *icon = [NSImageView imageViewWithImage:image];
    icon.contentTintColor = claude ? accent : NSColor.labelColor;
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    NSTextField *name = TBLabel(title, 13, NSFontWeightSemibold);
    NSMutableArray *headingViews = [NSMutableArray arrayWithObjects:icon, name, nil];
    if (snapshot.plan.length > 0) {
        NSTextField *plan = TBLabel(snapshot.plan, 10, NSFontWeightMedium);
        plan.textColor = NSColor.secondaryLabelColor;
        [headingViews addObject:plan];
    }
    [headingViews addObject:TBSpacer()];
    NSTextField *freshness = TBLabel(snapshot ? TBCaptureAge(snapshot.fetchedAt) : loading ? @"Checking…" : @"Unavailable",
                                     10, NSFontWeightRegular);
    freshness.textColor = NSColor.secondaryLabelColor;
    if (snapshot) {
        BOOL cached = error.length > 0 || -snapshot.fetchedAt.timeIntervalSinceNow >= 6 * 60;
        if (cached) freshness.stringValue = [@"Cached " stringByAppendingString:TBCaptureAge(snapshot.fetchedAt)];
        freshness.toolTip = [NSString stringWithFormat:@"Last measured %@%@", [NSDateFormatter localizedStringFromDate:snapshot.fetchedAt dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle],
            error.length ? [@". " stringByAppendingString:error] : @""];
    }
    [headingViews addObject:freshness];
    NSStackView *heading = TBStack(headingViews, NO, 7);
    NSStackView *section = TBStack(@[heading], YES, 12);
    [heading.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;

    if (snapshot) {
        NSMutableArray *mainWindows = [NSMutableArray new];
        NSMutableArray *modelWindows = [NSMutableArray new];
        for (TBUsageWindow *window in snapshot.windows) {
            BOOL primary = !claude || [window.identifier isEqual:@"claude-session"] || [window.identifier isEqual:@"claude-weekly"];
            [(primary ? mainWindows : modelWindows) addObject:window];
        }
        NSArray *visibleWindows = self.modelLimitsExpanded || mainWindows.count == 0
            ? snapshot.windows : mainWindows;
        for (TBUsageWindow *window in visibleWindows) {
            NSView *row = [self usageRow:window accent:accent];
            [section addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
        }
        if (modelWindows.count > 0 && mainWindows.count > 0) {
            NSString *label = [NSString stringWithFormat:@"%lu model limit%@", (unsigned long)modelWindows.count, modelWindows.count == 1 ? @"" : @"s"];
            NSButton *disclosure = [NSButton buttonWithTitle:label target:self action:@selector(toggleModelLimits:)];
            disclosure.bordered = NO;
            disclosure.font = [NSFont systemFontOfSize:10];
            disclosure.contentTintColor = NSColor.secondaryLabelColor;
            for (TBUsageWindow *window in modelWindows) if (window.usedPercent >= 75) disclosure.contentTintColor = NSColor.systemOrangeColor;
            disclosure.image = [NSImage imageWithSystemSymbolName:self.modelLimitsExpanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
            disclosure.imagePosition = NSImageLeft;
            disclosure.imageScaling = NSImageScaleProportionallyDown;
            disclosure.toolTip = @"Show or hide additional model-specific weekly allowances";
            [section addArrangedSubview:disclosure];
        }
    } else if (loading) {
        NSTextField *label = TBLabel(@"Reading your plan usage…", 11, NSFontWeightRegular);
        label.textColor = NSColor.secondaryLabelColor;
        [section addArrangedSubview:label];
    }
    if (error.length > 0 || (!snapshot && !loading)) {
        NSString *message = error.length ? error : @"Usage is temporarily unavailable.";
        if ([error containsString:@"rate limiting"]) {
            NSDate *retry = snapshot.nextRefreshAt ?: self.nextAutomaticRefreshAt;
            message = retry.timeIntervalSinceNow > 0
                ? [@"Rate limited. Retrying in " stringByAppendingString:TBDuration(retry.timeIntervalSinceNow)]
                : @"Rate limited. Waiting to retry.";
        }
        NSTextField *issue = TBLabel(message, 11, NSFontWeightRegular);
        issue.textColor = NSColor.secondaryLabelColor;
        issue.maximumNumberOfLines = 3;
        issue.lineBreakMode = NSLineBreakByWordWrapping;
        issue.toolTip = error;
        [section addArrangedSubview:issue];
        [issue.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    }
    if (claude && (self.claudeNeedsAuthorization || self.claudeNeedsConnection)) {
        NSButton *action = [NSButton buttonWithTitle:self.connectingClaude ? @"Connecting…" :
            self.claudeNeedsAuthorization ? @"Authorize Claude access" : @"Connect Claude"
            target:self action:self.claudeNeedsAuthorization ? @selector(authorizeClaudePressed:) : @selector(connectClaudePressed:)];
        action.bezelStyle = NSBezelStyleRounded;
        action.controlSize = NSControlSizeSmall;
        action.enabled = !self.connectingClaude;
        [section addArrangedSubview:action];
    }
    return section;
}

- (NSView *)usageRow:(TBUsageWindow *)window accent:(NSColor *)accent {
    NSString *title = window.title;
    if ([window.identifier isEqualToString:@"claude-session"]) title = @"Session";
    if ([window.identifier isEqualToString:@"claude-weekly"]) title = @"Weekly";
    title = [title stringByReplacingOccurrencesOfString:@"Weekly · " withString:@"Weekly, "];
    NSTextField *name = TBLabel(title, 12, NSFontWeightMedium);
    name.toolTip = window.title;
    NSTextField *value = TBLabel([TBPercent(window.usedPercent) stringByAppendingString:@" used"], 12, NSFontWeightMedium);
    value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSStackView *labels = TBStack(@[name, TBSpacer(), value], NO, 4);

    TBProgressView *progress = [TBProgressView new];
    progress.value = window.usedPercent;
    progress.barColor = window.usedPercent >= 90 ? NSColor.systemRedColor :
        window.usedPercent >= 75 ? NSColor.systemOrangeColor : accent;
    [progress.heightAnchor constraintEqualToConstant:5].active = YES;
    progress.toolTip = [NSString stringWithFormat:@"%@ used, %@ remaining", TBPercent(window.usedPercent), TBPercent(100 - window.usedPercent)];
    [progress setAccessibilityElement:YES];
    [progress setAccessibilityLabel:[title stringByAppendingString:@" usage"]];
    [progress setAccessibilityValue:TBPercent(window.usedPercent)];

    NSString *reset = @"";
    if (window.resetsAt) reset = window.resetsAt.timeIntervalSinceNow > 0
        ? [@"Resets in " stringByAppendingString:TBDuration(window.resetsAt.timeIntervalSinceNow)]
        : @"Reset passed. Awaiting update.";
    NSTextField *resetLabel = TBLabel(reset, 10, NSFontWeightRegular);
    resetLabel.textColor = NSColor.secondaryLabelColor;
    if (window.resetsAt) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterFullStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        resetLabel.toolTip = [formatter stringFromDate:window.resetsAt];
    }
    NSTextField *remaining = TBLabel([TBPercent(100 - window.usedPercent) stringByAppendingString:@" left"], 10, NSFontWeightRegular);
    remaining.textColor = NSColor.secondaryLabelColor;
    NSStackView *meta = TBStack(@[resetLabel, TBSpacer(), remaining], NO, 4);
    NSStackView *row = TBStack(@[labels, progress, meta], YES, 6);
    for (NSView *child in row.arrangedSubviews) [child.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
    return row;
}

- (void)toggleModelLimits:(id)sender {
    self.modelLimitsExpanded = !self.modelLimitsExpanded;
    [self render];
}

- (void)refreshPressed:(id)sender { if (self.onRefresh) self.onRefresh(); }
- (void)authorizeClaudePressed:(id)sender { if (self.onAuthorizeClaude) self.onAuthorizeClaude(); }
- (void)connectClaudePressed:(id)sender { if (self.onConnectClaude) self.onConnectClaude(); }

- (void)settingsPressed:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *usage = [[NSMenuItem alloc] initWithTitle:@"Open Claude Usage…" action:@selector(openClaudeUsage:) keyEquivalent:@""];
    usage.target = self;
    [menu addItem:usage];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit TokenBar" action:@selector(quitPressed:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 5) inView:sender];
}

- (void)toggleLaunchAtLogin:(id)sender {
    NSError *error = nil;
    BOOL enabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    BOOL success = enabled ? [SMAppService.mainAppService unregisterAndReturnError:&error]
                          : [SMAppService.mainAppService registerAndReturnError:&error];
    self.settingsMessageLabel.stringValue = success ? @"" : error.localizedDescription;
    self.settingsMessageLabel.hidden = success;
    [self render];
}

- (void)openClaudeUsage:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]];
}
- (void)quitPressed:(id)sender { [NSApp terminate:nil]; }
@end

@interface TBAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) NSPopover *popover;
@property(nonatomic) TBTokenBarViewController *viewController;
@property(nonatomic) TBCodexUsageService *codexService;
@property(nonatomic) TBClaudeUsageService *claudeService;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSWindow *previewWindow;
@property(nonatomic) NSDate *lastInteractionAt;
@property(nonatomic) NSDate *lastRefreshAttemptAt;
@end

@implementation TBAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"didConfigureLaunchAtLogin"] == nil) {
        NSError *loginError = nil;
        [SMAppService.mainAppService registerAndReturnError:&loginError];
        [defaults setBool:YES forKey:@"didConfigureLaunchAtLogin"];
    }

    self.codexService = [TBCodexUsageService new];
    self.claudeService = [TBClaudeUsageService new];
    self.viewController = [TBTokenBarViewController new];
    [self.viewController loadView];

    __weak typeof(self) weakSelf = self;
    self.viewController.onRefresh = ^{ [weakSelf refreshWithUserInitiated:YES]; };
    self.viewController.onConnectClaude = ^{ [weakSelf connectClaude]; };
    self.viewController.onAuthorizeClaude = ^{ [weakSelf authorizeClaude]; };

    self.popover = [NSPopover new];
    self.popover.contentSize = NSMakeSize(TBPanelWidth, 350);
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = self.viewController;

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"TokenBarStatusItem";
    NSStatusBarButton *button = self.statusItem.button;
    button.attributedTitle = [self statusTitleWithCodex:@"--" claude:@"--"];
    button.target = self;
    button.action = @selector(togglePopover:);

    self.viewController.codexLoading = NO;
    self.viewController.claudeLoading = NO;
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:15
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                       [weakSelf timerTick];
                                                   }];

    if ([NSProcessInfo.processInfo.arguments containsObject:@"--show-popover"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self togglePopover:nil];
        });
    }

    BOOL previewRequested = NSProcessInfo.processInfo.environment[@"TOKENBAR_PREVIEW_WINDOW"] != nil ||
                            [NSProcessInfo.processInfo.arguments containsObject:@"--preview-window"];
    if (previewRequested) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           self.previewWindow = [[NSWindow alloc]
                               initWithContentRect:NSMakeRect(0, 0, TBPanelWidth, self.viewController.preferredContentSize.height)
                                         styleMask:NSWindowStyleMaskTitled |
                                                   NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
                           self.previewWindow.title = @"TokenBar Preview";
                           self.previewWindow.releasedWhenClosed = NO;
                           self.lastInteractionAt = NSDate.date;
                           [self updateSchedule];
                           [self.viewController render];
                           self.previewWindow.contentViewController = self.viewController;
                           [self.previewWindow center];
                           [self.previewWindow makeKeyAndOrderFront:nil];
                           [NSApp activateIgnoringOtherApps:YES];
                       });
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!self.popover.shown && !self.previewWindow.visible) [self togglePopover:nil];
    return YES;
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) {
        [self.popover performClose:nil];
    } else {
        self.lastInteractionAt = NSDate.date;
        [self refreshWithUserInitiated:NO];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
        [self.viewController render];
        [self.popover.contentViewController.view.window makeKeyWindow];
    }
}

- (NSDate *)nextAutomaticRefresh {
    NSDate *now = NSDate.date;
    NSProcessInfo *process = NSProcessInfo.processInfo;
    BOOL recentlyViewed = self.popover.shown || self.previewWindow.visible ||
        (self.lastInteractionAt && [now timeIntervalSinceDate:self.lastInteractionAt] <= 5 * 60);
    // Keep the visible panel current even when macOS gives this utility a low-power budget.
    // Thermal pressure and idle low-power operation still use the slower cadence.
    BOOL constrained = process.thermalState >= NSProcessInfoThermalStateSerious ||
        (process.lowPowerModeEnabled && !recentlyViewed);
    if (NSProcessInfo.processInfo.environment[@"TOKENBAR_DEBUG_REFRESH"]) {
        NSLog(@"TokenBar refresh policy: interacted=%d lowPower=%d thermal=%ld interval=%.0f",
            self.lastInteractionAt != nil, process.lowPowerModeEnabled, (long)process.thermalState,
            [TBRefreshPolicy intervalAt:now lastInteraction:self.lastInteractionAt constrained:constrained]);
    }
    return [TBRefreshPolicy nextRefreshAt:now snapshot:self.viewController.claudeSnapshot
        lastAttempt:self.lastRefreshAttemptAt lastInteraction:self.lastInteractionAt constrained:constrained
        earliestRequest:self.claudeService.nextRequestAt retrying:self.viewController.claudeError.length > 0];
}

- (void)updateSchedule {
    self.viewController.nextAutomaticRefreshAt = [self nextAutomaticRefresh];
}

- (void)timerTick {
    NSDate *next = [self nextAutomaticRefresh];
    if (next.timeIntervalSinceNow <= 0) [self refreshWithUserInitiated:NO];
    [self updateSchedule];
    [self updateStatusTitle];
    if (self.popover.shown || self.previewWindow.visible) [self.viewController render];
}

- (void)refresh { [self refreshWithUserInitiated:NO]; }

- (void)refreshWithUserInitiated:(BOOL)userInitiated {
    if (self.viewController.codexLoading || self.viewController.claudeLoading || self.viewController.connectingClaude) return;
    NSDate *now = NSDate.date;
    if (userInitiated) self.lastInteractionAt = now;
    BOOL codexDue = !self.viewController.codexSnapshot ||
        [now timeIntervalSinceDate:self.viewController.codexSnapshot.fetchedAt] >= 60;
    BOOL claudeDue = !self.viewController.claudeSnapshot || !self.claudeService.nextRequestAt ||
        self.claudeService.nextRequestAt.timeIntervalSinceNow <= 0;
    if (!codexDue && !claudeDue) {
        [self updateSchedule];
        [self.viewController render];
        return;
    }
    self.lastRefreshAttemptAt = now;
    self.viewController.codexLoading = codexDue;
    self.viewController.claudeLoading = claudeDue;
    [self.viewController render];
    __weak typeof(self) weakSelf = self;
    if (codexDue) [self.codexService fetchWithCompletion:^(TBProviderSnapshot *snapshot, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.viewController.codexLoading = NO;
            if (snapshot) self.viewController.codexSnapshot = snapshot;
            self.viewController.codexError = error.localizedDescription;
            [self updateSchedule];
            [self updateStatusTitle];
            [self.viewController render];
        });
    }];
    if (claudeDue) [self.claudeService fetchWithUserInitiated:userInitiated completion:^(TBProviderSnapshot *snapshot, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.viewController.claudeLoading = NO;
            self.viewController.claudeSnapshot = snapshot;
            self.viewController.claudeNeedsConnection = [error.domain isEqualToString:TBUsageErrorDomain] && error.code == TBClaudeErrorSignInRequired;
            self.viewController.claudeNeedsAuthorization = [error.domain isEqualToString:TBUsageErrorDomain] && error.code == TBClaudeErrorKeychainAccess;
            self.viewController.claudeError = error.localizedDescription;
            [self updateSchedule];
            [self updateStatusTitle];
            [self.viewController render];
        });
    }];
}

- (void)authorizeClaude {
    self.viewController.connectingClaude = YES;
    [self.viewController render];
    __weak typeof(self) weakSelf = self;
    [self.claudeService authorizeWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.viewController.connectingClaude = NO;
            self.viewController.settingsMessageLabel.stringValue = error ? error.localizedDescription : @"Claude access authorized.";
            self.viewController.settingsMessageLabel.hidden = NO;
            [self refreshWithUserInitiated:YES];
        });
    }];
}

- (void)connectClaude {
    self.viewController.connectingClaude = YES;
    self.viewController.settingsMessageLabel.stringValue = @"Complete Claude sign-in in your browser.";
    self.viewController.settingsMessageLabel.hidden = NO;
    [self.viewController render];

    __weak typeof(self) weakSelf = self;
    [self.claudeService connectWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            self.viewController.connectingClaude = NO;
            if (error != nil) {
                self.viewController.settingsMessageLabel.stringValue = error.localizedDescription;
                self.viewController.settingsMessageLabel.hidden = NO;
                [self.viewController render];
            } else {
                self.viewController.settingsMessageLabel.stringValue = @"Claude connected.";
                self.viewController.settingsMessageLabel.hidden = NO;
                [self refreshWithUserInitiated:YES];
            }
        });
    }];
}

- (void)updateStatusTitle {
    NSString *codex = [self percentageForSnapshot:self.viewController.codexSnapshot
                                       identifier:@"codex-weekly"];
    NSString *claude = [self percentageForSnapshot:self.viewController.claudeSnapshot
                                        identifier:@"claude-session"];
    if (self.viewController.claudeSnapshot &&
        (self.viewController.claudeError.length > 0 ||
         [NSDate.date timeIntervalSinceDate:self.viewController.claudeSnapshot.fetchedAt] >= 6 * 60)) {
        claude = [@"~" stringByAppendingString:claude];
    }
    self.statusItem.button.attributedTitle = [self statusTitleWithCodex:codex claude:claude];
    self.statusItem.button.toolTip = self.viewController.claudeError.length > 0
        ? [@"Claude: " stringByAppendingString:self.viewController.claudeError]
        : @"Codex weekly · Claude 5-hour session";
}

- (NSAttributedString *)statusTitleWithCodex:(NSString *)codex claude:(NSString *)claude {
    NSMutableAttributedString *title = [NSMutableAttributedString new];
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSDictionary *valueAttributes = @{
        NSFontAttributeName: valueFont,
        NSForegroundColorAttributeName: NSColor.labelColor,
    };
    NSDictionary *codexMark = @{
        NSFontAttributeName: [NSFont systemFontOfSize:7 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.37 green:0.59 blue:0.88 alpha:1],
        NSBaselineOffsetAttributeName: @1,
    };
    NSDictionary *claudeMark = @{
        NSFontAttributeName: [NSFont systemFontOfSize:7 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.86 green:0.48 blue:0.28 alpha:1],
        NSBaselineOffsetAttributeName: @1,
    };
    NSDictionary *spacingAttributes = @{
        NSFontAttributeName: valueFont,
        NSForegroundColorAttributeName: NSColor.clearColor,
    };

    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"●" attributes:codexMark]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:spacingAttributes]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:codex attributes:valueAttributes]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:spacingAttributes]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"●" attributes:claudeMark]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:spacingAttributes]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:claude attributes:valueAttributes]];
    return title;
}

- (NSString *)percentageForSnapshot:(TBProviderSnapshot *)snapshot identifier:(NSString *)identifier {
    for (TBUsageWindow *window in snapshot.windows) {
        if ([window.identifier isEqualToString:identifier]) {
            return TBPercent(window.usedPercent);
        }
    }
    return @"--";
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [TBClaudeUsageService disableAutomaticKeychainInteraction];
        NSApplication *application = NSApplication.sharedApplication;
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]) {
            if (other.processIdentifier != NSProcessInfo.processInfo.processIdentifier) return 0;
        }
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        TBAppDelegate *delegate = [TBAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
