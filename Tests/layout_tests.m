#define main TBTokenBarApplicationEntryPoint
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wnullability-completeness-on-arrays"
#import "../Sources/TokenBar/main.m"
#pragma clang diagnostic pop
#undef main

static TBProviderSnapshot *SampleSnapshot(NSString *provider) {
    TBProviderSnapshot *snapshot = [TBProviderSnapshot new];
    snapshot.provider = provider;
    snapshot.plan = @"Max";
    snapshot.fetchedAt = [NSDate dateWithTimeIntervalSinceNow:-720];
    TBUsageWindow *window = [TBUsageWindow new];
    window.identifier = [provider isEqual:@"Claude"] ? @"claude-session" : @"codex-weekly";
    window.title = @"Weekly";
    window.usedPercent = 17;
    window.resetsAt = [NSDate dateWithTimeIntervalSinceNow:3600];
    snapshot.windows = @[window];
    if ([provider isEqual:@"Claude"]) {
        TBUsageWindow *weekly = [TBUsageWindow new];
        weekly.identifier = @"claude-weekly";
        weekly.title = @"Weekly";
        weekly.usedPercent = 5;
        TBUsageWindow *model = [TBUsageWindow new];
        model.identifier = @"claude-weekly-scoped-example";
        model.title = @"Weekly, Example";
        model.usedPercent = 2;
        snapshot.windows = @[window, weekly, model];
    }
    return snapshot;
}

static void AssertCompactLayout(TBTokenBarViewController *controller, NSString *state) {
    NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1800, 900)];
    [host addSubview:controller.view];
    for (int iteration = 0; iteration < 12; iteration++) {
        [controller render];
        // Simulate an AppKit host proposing a much wider frame while sizing a popover.
        // The panel must resist that proposal instead of expanding its content/window.
        [controller.view setFrameSize:NSMakeSize(1600, controller.preferredContentSize.height)];
        host.needsLayout = YES;
        [host layoutSubtreeIfNeeded];
        NSSize fitting = controller.view.fittingSize;
        NSSize preferred = controller.preferredContentSize;
        NSCAssert(fabs(controller.view.bounds.size.width - TBPanelWidth) < 1,
                  @"%@ accepted an oversized host frame: %@", state, NSStringFromSize(controller.view.bounds.size));
        NSCAssert(fabs(fitting.width - TBPanelWidth) < 1,
                  @"%@ grew beyond the panel width: %@", state, NSStringFromSize(fitting));
        NSCAssert(fabs(preferred.width - TBPanelWidth) < 1 && preferred.height < 700,
                  @"%@ must remain a compact panel: %@", state, NSStringFromSize(preferred));
    }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        TBTokenBarViewController *controller = [TBTokenBarViewController new];
        [controller loadView];
        controller.codexSnapshot = SampleSnapshot(@"Codex");
        controller.claudeSnapshot = SampleSnapshot(@"Claude");

        controller.claudeNeedsAuthorization = YES;
        controller.claudeError = @"Claude Keychain access is unavailable. Authorize access when ready; automatic checks will stay silent.";
        AssertCompactLayout(controller, @"Keychain permission error");

        controller.claudeNeedsAuthorization = NO;
        controller.claudeError = nil;
        AssertCompactLayout(controller, @"Loaded usage");
        CGFloat collapsedHeight = controller.preferredContentSize.height;
        controller.modelLimitsExpanded = YES;
        AssertCompactLayout(controller, @"Expanded model limits");
        NSCAssert(controller.preferredContentSize.height > collapsedHeight, @"Expansion should add height only");
        controller.modelLimitsExpanded = NO;
        AssertCompactLayout(controller, @"Collapsed model limits");
        NSCAssert(fabs(controller.preferredContentSize.height - collapsedHeight) < 1, @"Collapse must restore compact height");

        controller.claudeError = [@"An unexpectedly long provider failure description " stringByPaddingToLength:5000
            withString:@" with more diagnostic text" startingAtIndex:0];
        controller.settingsMessageLabel.stringValue = controller.claudeError;
        controller.settingsMessageLabel.hidden = NO;
        AssertCompactLayout(controller, @"Long diagnostic and settings errors");

        controller.settingsMessageLabel.hidden = YES;
        controller.claudeError = @"Anthropic is rate limiting usage checks. Automatic retry is scheduled.";
        AssertCompactLayout(controller, @"Rate limit");

        controller.claudeSnapshot = nil;
        controller.claudeNeedsConnection = YES;
        controller.claudeError = @"Claude Code has no saved sign-in. Connect Claude to continue.";
        AssertCompactLayout(controller, @"Missing credentials");
        NSLog(@"TokenBar layout tests passed");
    }
    return 0;
}
