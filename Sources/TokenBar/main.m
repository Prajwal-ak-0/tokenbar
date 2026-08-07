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

@interface TBFlippedView : NSView
@end

@implementation TBFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface TBTokenBarViewController : NSViewController
@property(nonatomic, copy) dispatch_block_t onRefresh;
@property(nonatomic, copy) dispatch_block_t onConnectClaude;
@property(nonatomic, nullable) TBProviderSnapshot *codexSnapshot;
@property(nonatomic, nullable) TBProviderSnapshot *claudeSnapshot;
@property(nonatomic, nullable, copy) NSString *codexError;
@property(nonatomic, nullable, copy) NSString *claudeError;
@property(nonatomic) BOOL codexLoading;
@property(nonatomic) BOOL claudeLoading;
@property(nonatomic) BOOL claudeNeedsConnection;
@property(nonatomic) BOOL connectingClaude;
@property(nonatomic, nullable) NSDate *lastUpdated;
@property(nonatomic) NSTextField *updatedLabel;
@property(nonatomic) NSButton *refreshButton;
@property(nonatomic) NSStackView *contentStack;
@property(nonatomic) NSSwitch *loginSwitch;
@property(nonatomic) NSTextField *settingsMessageLabel;
- (void)render;
@end

@implementation TBTokenBarViewController

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 382, 580)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    self.view = root;

    NSStackView *outer = [NSStackView new];
    outer.orientation = NSUserInterfaceLayoutOrientationVertical;
    outer.alignment = NSLayoutAttributeLeading;
    outer.spacing = 0;
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:outer];
    [NSLayoutConstraint activateConstraints:@[
        [outer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [outer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [outer.topAnchor constraintEqualToAnchor:root.topAnchor],
        [outer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    NSView *header = [self headerView];
    [outer addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:outer.widthAnchor].active = YES;
    [outer addArrangedSubview:TBSeparator()];

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    self.contentStack = [NSStackView new];
    self.contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.contentStack.alignment = NSLayoutAttributeLeading;
    self.contentStack.spacing = 20;
    self.contentStack.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *document = [TBFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:self.contentStack];
    scroll.documentView = document;
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
    [outer addArrangedSubview:scroll];
    [scroll.widthAnchor constraintEqualToAnchor:outer.widthAnchor].active = YES;
    [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationVertical];

    [outer addArrangedSubview:TBSeparator()];
    NSView *footer = [self footerView];
    [outer addArrangedSubview:footer];
    [footer.widthAnchor constraintEqualToAnchor:outer.widthAnchor].active = YES;

    self.codexLoading = YES;
    self.claudeLoading = YES;
    [self render];
}

- (NSView *)headerView {
    NSView *header = [NSView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header.heightAnchor constraintEqualToConstant:66].active = YES;

    NSTextField *title = TBLabel(@"TokenBar", 18, NSFontWeightSemibold);
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.updatedLabel = TBLabel(@"Reading account usage…", 11, NSFontWeightRegular);
    self.updatedLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *labels = [NSStackView stackViewWithViews:@[title, self.updatedLabel]];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 3;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:labels];

    self.refreshButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise"
                                                                        accessibilityDescription:@"Refresh usage"]
                                       target:self
                                       action:@selector(refreshPressed:)];
    self.refreshButton.bordered = NO;
    self.refreshButton.toolTip = @"Refresh usage";
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.refreshButton];

    [NSLayoutConstraint activateConstraints:@[
        [labels.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:18],
        [labels.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.refreshButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.refreshButton.widthAnchor constraintEqualToConstant:28],
        [self.refreshButton.heightAnchor constraintEqualToConstant:28],
    ]];
    return header;
}

- (NSView *)footerView {
    NSView *footer = [NSView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *loginLabel = TBLabel(@"Launch at login", 12, NSFontWeightRegular);
    self.loginSwitch = [NSSwitch new];
    self.loginSwitch.controlSize = NSControlSizeSmall;
    self.loginSwitch.target = self;
    self.loginSwitch.action = @selector(loginSwitchChanged:);
    self.loginSwitch.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;

    NSStackView *loginRow = [NSStackView stackViewWithViews:@[loginLabel, self.loginSwitch]];
    loginRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    loginRow.distribution = NSStackViewDistributionFill;
    loginRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.settingsMessageLabel = TBLabel(@"", 10, NSFontWeightRegular);
    self.settingsMessageLabel.textColor = NSColor.secondaryLabelColor;
    self.settingsMessageLabel.maximumNumberOfLines = 2;
    self.settingsMessageLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.settingsMessageLabel.hidden = YES;

    NSButton *usageButton = [NSButton buttonWithTitle:@"Claude usage page"
                                               target:self
                                               action:@selector(openClaudeUsage:)];
    usageButton.bezelStyle = NSBezelStyleInline;
    usageButton.bordered = NO;
    usageButton.contentTintColor = NSColor.secondaryLabelColor;

    NSButton *quitButton = [NSButton buttonWithTitle:@"Quit TokenBar"
                                              target:self
                                              action:@selector(quitPressed:)];
    quitButton.bezelStyle = NSBezelStyleInline;
    quitButton.bordered = NO;
    quitButton.contentTintColor = NSColor.secondaryLabelColor;

    NSStackView *buttonRow = [NSStackView stackViewWithViews:@[usageButton, quitButton]];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.distribution = NSStackViewDistributionEqualSpacing;

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        loginRow, self.settingsMessageLabel, buttonRow,
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:11],
        [stack.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-11],
        [loginRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.settingsMessageLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [buttonRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    return footer;
}

- (void)render {
    if (!self.viewLoaded) return;
    for (NSView *view in self.contentStack.arrangedSubviews.copy) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSView *codex = [self providerViewWithTitle:@"Codex"
                                       subtitle:@"Weekly allowance"
                                       snapshot:self.codexSnapshot
                                         error:self.codexError
                                       loading:self.codexLoading
                               needsConnection:NO];
    [self.contentStack addArrangedSubview:codex];
    [codex.widthAnchor constraintEqualToAnchor:self.contentStack.widthAnchor constant:-36].active = YES;
    [self.contentStack addArrangedSubview:TBSeparator()];

    NSView *claude = [self providerViewWithTitle:@"Claude"
                                        subtitle:@"Session and weekly allowances"
                                        snapshot:self.claudeSnapshot
                                          error:self.claudeError
                                        loading:self.claudeLoading
                                needsConnection:self.claudeNeedsConnection];
    [self.contentStack addArrangedSubview:claude];
    [claude.widthAnchor constraintEqualToAnchor:self.contentStack.widthAnchor constant:-36].active = YES;

    if (self.lastUpdated != nil) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        self.updatedLabel.stringValue = [NSString stringWithFormat:@"Updated %@",
                                         [formatter stringFromDate:self.lastUpdated]];
    }
    self.refreshButton.enabled = !(self.codexLoading || self.claudeLoading);
}

- (NSView *)providerViewWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                         snapshot:(TBProviderSnapshot *)snapshot
                            error:(NSString *)error
                          loading:(BOOL)loading
                  needsConnection:(BOOL)needsConnection {
    NSStackView *section = [NSStackView new];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 13;

    NSTextField *mark = TBLabel([title isEqualToString:@"Codex"] ? @"C" : @"A",
                                10, NSFontWeightBold);
    mark.textColor = NSColor.whiteColor;
    mark.alignment = NSTextAlignmentCenter;
    mark.wantsLayer = YES;
    mark.layer.backgroundColor = [NSColor colorWithSRGBRed:0.15 green:0.18 blue:0.17 alpha:1].CGColor;
    mark.layer.cornerRadius = 6;
    [mark.widthAnchor constraintEqualToConstant:21].active = YES;
    [mark.heightAnchor constraintEqualToConstant:21].active = YES;

    NSTextField *heading = TBLabel(title, 15, NSFontWeightSemibold);
    NSStackView *headingRow = [NSStackView stackViewWithViews:@[mark, heading]];
    headingRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headingRow.alignment = NSLayoutAttributeCenterY;
    headingRow.spacing = 7;

    NSTextField *subtitleLabel = TBLabel(subtitle, 11, NSFontWeightRegular);
    subtitleLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *headingGroup = [NSStackView stackViewWithViews:@[headingRow, subtitleLabel]];
    headingGroup.orientation = NSUserInterfaceLayoutOrientationVertical;
    headingGroup.alignment = NSLayoutAttributeLeading;
    headingGroup.spacing = 3;

    NSView *headingSpacer = [NSView new];
    [headingSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSView *> *topViews = [NSMutableArray arrayWithObjects:headingGroup, headingSpacer, nil];
    if (snapshot.plan.length > 0) {
        NSTextField *plan = TBLabel(snapshot.plan, 10, NSFontWeightMedium);
        plan.textColor = NSColor.secondaryLabelColor;
        [topViews addObject:plan];
    }
    NSStackView *top = [NSStackView stackViewWithViews:topViews];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.distribution = NSStackViewDistributionFill;
    [section addArrangedSubview:top];
    [top.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;

    if (loading) {
        NSTextField *loadingLabel = TBLabel(@"Reading account usage…", 12, NSFontWeightRegular);
        loadingLabel.textColor = NSColor.secondaryLabelColor;
        NSProgressIndicator *indicator = [NSProgressIndicator new];
        indicator.style = NSProgressIndicatorStyleBar;
        indicator.indeterminate = YES;
        [indicator startAnimation:nil];
        [section addArrangedSubview:loadingLabel];
        [section addArrangedSubview:indicator];
        [indicator.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    } else if (snapshot != nil) {
        for (TBUsageWindow *window in snapshot.windows) {
            NSView *row = [self usageRow:window];
            [section addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
        }
    } else {
        NSStackView *state = [NSStackView new];
        state.orientation = NSUserInterfaceLayoutOrientationVertical;
        state.alignment = NSLayoutAttributeLeading;
        state.spacing = 9;
        state.edgeInsets = NSEdgeInsetsMake(11, 11, 11, 11);
        state.wantsLayer = YES;
        state.layer.backgroundColor = NSColor.quaternaryLabelColor.CGColor;
        state.layer.cornerRadius = 10;

        NSString *message = needsConnection
            ? @"Connect Claude Code to show exact usage."
            : (error.length > 0 ? error : @"Usage is temporarily unavailable.");
        NSTextField *messageLabel = TBLabel(message, 12, NSFontWeightRegular);
        messageLabel.textColor = NSColor.secondaryLabelColor;
        messageLabel.maximumNumberOfLines = 3;
        messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [state addArrangedSubview:messageLabel];
        [messageLabel.widthAnchor constraintLessThanOrEqualToAnchor:state.widthAnchor constant:-22].active = YES;

        if (needsConnection) {
            NSString *buttonTitle = self.connectingClaude ? @"Connecting…" : @"Connect Claude";
            NSButton *button = [NSButton buttonWithTitle:buttonTitle
                                                  target:self
                                                  action:@selector(connectClaudePressed:)];
            button.bezelStyle = NSBezelStyleRounded;
            button.contentTintColor = TBAccentColor();
            button.enabled = !self.connectingClaude;
            [state addArrangedSubview:button];
        }
        [section addArrangedSubview:state];
        [state.widthAnchor constraintEqualToAnchor:section.widthAnchor].active = YES;
    }
    return section;
}

- (NSView *)usageRow:(TBUsageWindow *)window {
    NSStackView *row = [NSStackView new];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 7;

    double percent = MIN(MAX(window.usedPercent, 0), 100);
    NSTextField *title = TBLabel(window.title, 12, NSFontWeightMedium);
    NSTextField *value = TBLabel([NSString stringWithFormat:@"%.0f%%", percent],
                                12, NSFontWeightSemibold);
    value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    NSStackView *labelRow = [NSStackView stackViewWithViews:@[title, value]];
    labelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    labelRow.distribution = NSStackViewDistributionEqualSpacing;
    [row addArrangedSubview:labelRow];
    [labelRow.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;

    TBProgressView *progress = [TBProgressView new];
    progress.value = percent;
    if (percent >= 90) {
        progress.barColor = [NSColor colorWithSRGBRed:0.72 green:0.25 blue:0.22 alpha:1];
    } else if (percent >= 75) {
        progress.barColor = [NSColor colorWithSRGBRed:0.72 green:0.48 blue:0.16 alpha:1];
    } else {
        progress.barColor = TBAccentColor();
    }
    [progress.heightAnchor constraintEqualToConstant:7].active = YES;
    [row addArrangedSubview:progress];
    [progress.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;

    NSTextField *remaining = TBLabel([NSString stringWithFormat:@"%.0f%% remaining", 100 - percent],
                                    10, NSFontWeightRegular);
    remaining.textColor = NSColor.secondaryLabelColor;
    NSMutableArray<NSView *> *metaViews = [NSMutableArray arrayWithObject:remaining];
    if (window.resetsAt != nil) {
        NSRelativeDateTimeFormatter *relative = [NSRelativeDateTimeFormatter new];
        relative.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
        NSString *resetText = [relative localizedStringForDate:window.resetsAt relativeToDate:NSDate.date];
        NSTextField *reset = TBLabel([@"Resets " stringByAppendingString:resetText],
                                    10, NSFontWeightRegular);
        reset.textColor = NSColor.secondaryLabelColor;
        [metaViews addObject:reset];
    }
    NSStackView *meta = [NSStackView stackViewWithViews:metaViews];
    meta.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    meta.distribution = NSStackViewDistributionEqualSpacing;
    [row addArrangedSubview:meta];
    [meta.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
    return row;
}

- (void)refreshPressed:(id)sender {
    if (self.onRefresh) self.onRefresh();
}

- (void)connectClaudePressed:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Connect Claude Code?";
    alert.informativeText = @"TokenBar will open Anthropic’s browser sign-in. Claude Code keeps the credential in macOS Keychain.";
    [alert addButtonWithTitle:@"Connect"];
    [alert addButtonWithTitle:@"Cancel"];

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window
                 completionHandler:^(NSModalResponse response) {
                     if (response == NSAlertFirstButtonReturn && weakSelf.onConnectClaude) {
                         weakSelf.onConnectClaude();
                     }
                 }];
}

- (void)loginSwitchChanged:(NSSwitch *)sender {
    NSError *error = nil;
    BOOL enable = sender.state == NSControlStateValueOn;
    BOOL success = enable
        ? [SMAppService.mainAppService registerAndReturnError:&error]
        : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!success) {
        sender.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
            ? NSControlStateValueOn : NSControlStateValueOff;
        self.settingsMessageLabel.stringValue = [NSString stringWithFormat:@"Could not update login setting: %@",
                                                  error.localizedDescription];
        self.settingsMessageLabel.hidden = NO;
    } else {
        self.settingsMessageLabel.hidden = YES;
    }
}

- (void)openClaudeUsage:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]];
}

- (void)quitPressed:(id)sender {
    [NSApp terminate:nil];
}

@end

@interface TBAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) NSPopover *popover;
@property(nonatomic) TBTokenBarViewController *viewController;
@property(nonatomic) TBCodexUsageService *codexService;
@property(nonatomic) TBClaudeUsageService *claudeService;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSWindow *previewWindow;
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
    self.viewController.onRefresh = ^{ [weakSelf refresh]; };
    self.viewController.onConnectClaude = ^{ [weakSelf connectClaude]; };

    self.popover = [NSPopover new];
    self.popover.contentSize = NSMakeSize(382, 580);
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentViewController = self.viewController;

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"TokenBarStatusItem";
    NSStatusBarButton *button = self.statusItem.button;
    button.attributedTitle = [self statusTitleWithCodex:@"--" claude:@"--"];
    button.target = self;
    button.action = @selector(togglePopover:);

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:15 * 60
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                       [weakSelf refresh];
                                                   }];

    BOOL previewRequested = NSProcessInfo.processInfo.environment[@"TOKENBAR_PREVIEW_WINDOW"] != nil ||
                            [NSProcessInfo.processInfo.arguments containsObject:@"--preview-window"];
    if (previewRequested) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           self.previewWindow = [[NSWindow alloc]
                               initWithContentRect:NSMakeRect(0, 0, 382, 580)
                                         styleMask:NSWindowStyleMaskTitled |
                                                   NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
                           self.previewWindow.title = @"TokenBar Preview";
                           self.previewWindow.contentViewController = self.viewController;
                           [self.previewWindow center];
                           [self.previewWindow makeKeyAndOrderFront:nil];
                           [NSApp activateIgnoringOtherApps:YES];
                       });
    }
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) {
        [self.popover performClose:nil];
    } else {
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
        [self.popover.contentViewController.view.window makeKeyWindow];
    }
}

- (void)refresh {
    self.viewController.codexLoading = YES;
    self.viewController.claudeLoading = YES;
    [self.viewController render];

    __weak typeof(self) weakSelf = self;
    [self.codexService fetchWithCompletion:^(TBProviderSnapshot *snapshot, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            self.viewController.codexLoading = NO;
            self.viewController.codexSnapshot = snapshot;
            self.viewController.codexError = error.localizedDescription;
            if (snapshot != nil) self.viewController.lastUpdated = snapshot.fetchedAt;
            [self updateStatusTitle];
            [self.viewController render];
        });
    }];

    [self.claudeService fetchWithCompletion:^(TBProviderSnapshot *snapshot, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil) return;
            self.viewController.claudeLoading = NO;
            self.viewController.claudeSnapshot = snapshot;
            self.viewController.claudeNeedsConnection = [error.localizedDescription isEqualToString:@"CONNECT_CLAUDE"];
            self.viewController.claudeError = self.viewController.claudeNeedsConnection
                ? nil : error.localizedDescription;
            if (snapshot != nil) self.viewController.lastUpdated = snapshot.fetchedAt;
            [self updateStatusTitle];
            [self.viewController render];
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
                [self refresh];
            }
        });
    }];
}

- (void)updateStatusTitle {
    NSString *codex = [self percentageForSnapshot:self.viewController.codexSnapshot
                                       identifier:@"codex-weekly"];
    NSString *claude = [self percentageForSnapshot:self.viewController.claudeSnapshot
                                        identifier:@"claude-session"];
    self.statusItem.button.attributedTitle = [self statusTitleWithCodex:codex claude:claude];
    self.statusItem.button.toolTip = @"Codex weekly · Claude 5-hour session";
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
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.18 green:0.68 blue:0.47 alpha:1],
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
            return [NSString stringWithFormat:@"%.0f%%", MIN(MAX(window.usedPercent, 0), 100)];
        }
    }
    return @"--";
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        TBAppDelegate *delegate = [TBAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
