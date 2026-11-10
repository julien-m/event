#import "ReminderKitBridge.h"
#import <dlfcn.h>

// ReminderKit is private and version-dependent. Keep this optional boundary
// isolated, check selectors, and surface errors instead of substituting alarms.
// API reference: https://github.com/viticci/remctl (MIT), remctl-private.m.
@protocol ReminderKitDeltaValue <NSObject>
- (NSInteger)unit;
- (NSInteger)count;
@end

@interface NSObject (ReminderKitScheduling)
+ (id)objectIDWithURL:(NSURL *)url;
- (id)fetchReminderWithObjectID:(id)objectID fetchOptions:(id)options error:(NSError **)error;
- (void)setIncludeDueDateDeltaAlerts:(BOOL)include;
- (id)initWithStore:(id)store;
- (id)updateReminder:(id)reminder;
- (id)urgentAlarmContext;
- (void)setIsUrgentStateEnabledForCurrentUser:(BOOL)value;
- (BOOL)isUrgentStateEnabledForCurrentUser;
- (id)dueDateDeltaAlertContext;
- (NSArray *)dueDateDeltaAlerts;
- (id)fetchedCurrentDueDateDeltaAlert;
- (id)identifier;
- (id)dueDateDelta;
- (void)removeDueDateDeltaAlertsWithIdentifiers:(NSArray *)identifiers;
- (void)removeAllFetchedDueDateDeltaAlerts;
- (id)initWithUnit:(NSInteger)unit count:(NSInteger)count;
- (id)addDueDateDeltaAlertWithDueDateDelta:(id)delta;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

static BOOL ReminderKitLoad(void) {
  static void *handle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW | RTLD_LOCAL);
  });
  return handle && NSClassFromString(@"REMStore") && NSClassFromString(@"REMObjectID")
    && NSClassFromString(@"REMSaveRequest");
}

BOOL ReminderKitEarlyReminderAvailable(void) {
  return ReminderKitLoad() && NSClassFromString(@"REMDueDateDeltaInterval")
    && NSClassFromString(@"REMReminderFetchOptions");
}

BOOL ReminderKitUrgentAvailable(void) {
  return ReminderKitLoad()
    && [NSClassFromString(@"REMReminderUrgentAlarmContextChangeItem") instancesRespondToSelector:@selector(setIsUrgentStateEnabledForCurrentUser:)]
    && [NSClassFromString(@"REMReminderUrgentAlarmContext") instancesRespondToSelector:@selector(isUrgentStateEnabledForCurrentUser)];
}

NSString *ReminderKitSetEarlyReminder(NSString *identifier, NSInteger minutes, BOOL clear) {
  @autoreleasepool {
    @try {
      if (![[NSUUID alloc] initWithUUIDString:identifier]) return @"Invalid reminder identifier.";
      if (!clear && (minutes < 1 || minutes > INT32_MAX)) return @"Invalid early reminder minutes.";
      if (!ReminderKitEarlyReminderAvailable()) return @"Native Early Reminder is unavailable on this macOS version.";
      Class ids = NSClassFromString(@"REMObjectID");
      if (![ids respondsToSelector:@selector(objectIDWithURL:)]) return @"ReminderKit object ID API unavailable.";
      NSURL *url = [NSURL URLWithString:[@"x-apple-reminderkit://REMCDReminder/" stringByAppendingString:identifier]];
      id objectID = [ids objectIDWithURL:url];
      id store = [NSClassFromString(@"REMStore") new];
      NSError *error = nil;
      if (![store respondsToSelector:@selector(fetchReminderWithObjectID:fetchOptions:error:)]) return @"ReminderKit fetch API unavailable.";
      id options = [NSClassFromString(@"REMReminderFetchOptions") new];
      if (![options respondsToSelector:@selector(setIncludeDueDateDeltaAlerts:)]) return @"ReminderKit Early Reminder fetch options unavailable.";
      [options setIncludeDueDateDeltaAlerts:YES];
      id reminder = [store fetchReminderWithObjectID:objectID fetchOptions:options error:&error];
      if (!reminder) return error.localizedDescription ?: @"ReminderKit could not find the reminder.";
      if (![reminder respondsToSelector:@selector(dueDateDeltaAlertContext)]) return @"Native Early Reminder read context unavailable.";
      id readContext = [reminder dueDateDeltaAlertContext];
      if (![readContext respondsToSelector:@selector(dueDateDeltaAlerts)]) return @"Native Early Reminder read API unavailable.";
      NSArray *existing = [readContext dueDateDeltaAlerts];
      if ([readContext respondsToSelector:@selector(fetchedCurrentDueDateDeltaAlert)]) {
        id current = [readContext fetchedCurrentDueDateDeltaAlert];
        if (current && ![existing containsObject:current]) existing = [(existing ?: @[]) arrayByAddingObject:current];
      }
      if (existing && ![existing isKindOfClass:[NSArray class]]) return @"Unexpected native Early Reminder collection.";
      NSMutableArray *identifiers = [NSMutableArray array];
      for (id alert in existing) {
        if (![alert respondsToSelector:@selector(identifier)] || ![alert identifier]) return @"Cannot identify an existing Early Reminder.";
        [identifiers addObject:[alert identifier]];
      }
      id save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
      if (![save respondsToSelector:@selector(updateReminder:)] || ![save respondsToSelector:@selector(saveSynchronouslyWithError:)]) return @"ReminderKit save API unavailable.";
      id change = [save updateReminder:reminder];
      if (![change respondsToSelector:@selector(dueDateDeltaAlertContext)]) return @"Native Early Reminder context unavailable.";
      id context = [change dueDateDeltaAlertContext];
      if (![context respondsToSelector:@selector(removeAllFetchedDueDateDeltaAlerts)] ||
          ![context respondsToSelector:@selector(addDueDateDeltaAlertWithDueDateDelta:)]) return @"Native Early Reminder mutation API unavailable.";
      if (![context respondsToSelector:@selector(removeDueDateDeltaAlertsWithIdentifiers:)]) return @"Native Early Reminder removal API unavailable.";
      if (identifiers.count) [context removeDueDateDeltaAlertsWithIdentifiers:identifiers];
      [context removeAllFetchedDueDateDeltaAlerts];
      if (!clear) {
        // ReminderKit unit 0 is minutes; a negative count means before due time.
        id delta = [[NSClassFromString(@"REMDueDateDeltaInterval") alloc] initWithUnit:0 count:-minutes];
        if (!delta || ![context addDueDateDeltaAlertWithDueDateDelta:delta]) return @"Could not create native Early Reminder.";
      }
      error = nil;
      if (![save saveSynchronouslyWithError:&error]) return error.localizedDescription ?: @"Native Early Reminder save failed.";
      // ReminderKit updates its fetch snapshots asynchronously after the save.
      // Poll reads only, with a two-second bound; never replay the mutation.
      for (NSInteger attempt = 0; attempt < 20; attempt++) {
        id verifyStore = [NSClassFromString(@"REMStore") new];
        id saved = [verifyStore fetchReminderWithObjectID:objectID fetchOptions:options error:&error];
        if (!saved) return error.localizedDescription ?: @"Could not verify saved Early Reminder.";
        id savedContext = [saved dueDateDeltaAlertContext];
        id current = [savedContext respondsToSelector:@selector(fetchedCurrentDueDateDeltaAlert)]
          ? [savedContext fetchedCurrentDueDateDeltaAlert] : nil;
        NSArray *alerts = [savedContext dueDateDeltaAlerts];
        if (clear && !current && alerts.count == 0) return nil;
        id<ReminderKitDeltaValue> delta = [current dueDateDelta];
        if (!clear && delta && [delta respondsToSelector:@selector(unit)] &&
            [delta respondsToSelector:@selector(count)] && [delta unit] == 0 && [delta count] == -minutes) return nil;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      }
      return @"Native Early Reminder write could not be verified within two seconds.";
    } @catch (NSException *exception) {
      return [@"ReminderKit scheduling failed: " stringByAppendingString:exception.reason ?: exception.name];
    }
  }
}


NSString *ReminderKitSetUrgent(NSString *identifier, BOOL urgent) {
  @autoreleasepool {
    @try {
      if (![[NSUUID alloc] initWithUUIDString:identifier]) return @"Invalid reminder identifier.";
      if (!ReminderKitUrgentAvailable()) return @"Native Urgent is unavailable on this macOS version.";
      Class ids = NSClassFromString(@"REMObjectID");
      if (![ids respondsToSelector:@selector(objectIDWithURL:)]) return @"ReminderKit object ID API unavailable.";
      id objectID = [ids objectIDWithURL:[NSURL URLWithString:[@"x-apple-reminderkit://REMCDReminder/" stringByAppendingString:identifier]]];
      id store = [NSClassFromString(@"REMStore") new];
      if (![store respondsToSelector:@selector(fetchReminderWithObjectID:fetchOptions:error:)]) return @"ReminderKit fetch API unavailable.";
      NSError *error = nil;
      id options = [NSClassFromString(@"REMReminderFetchOptions") new];
      if (!options) return @"ReminderKit Urgent fetch options unavailable.";
      id reminder = [store fetchReminderWithObjectID:objectID fetchOptions:options error:&error];
      if (!reminder) return [@"Urgent fetch failed: " stringByAppendingString:error.localizedDescription ?: @"Reminder not found."];
      id save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
      if (![save respondsToSelector:@selector(updateReminder:)] || ![save respondsToSelector:@selector(saveSynchronouslyWithError:)]) return @"ReminderKit save API unavailable.";
      id change = [save updateReminder:reminder];
      if (![change respondsToSelector:@selector(urgentAlarmContext)]) return @"Native Urgent context unavailable.";
      id context = [change urgentAlarmContext];
      if (![context respondsToSelector:@selector(setIsUrgentStateEnabledForCurrentUser:)]) return @"Native Urgent mutation API unavailable.";
      [context setIsUrgentStateEnabledForCurrentUser:urgent];
      if (![save saveSynchronouslyWithError:&error]) return error.localizedDescription ?: @"Native Urgent save failed.";
      for (NSInteger attempt = 0; attempt < 20; attempt++) {
        id verifyStore = [NSClassFromString(@"REMStore") new];
        error = nil;
        id saved = [verifyStore fetchReminderWithObjectID:objectID fetchOptions:options error:&error];
        if (!saved) return error.localizedDescription ?: @"Could not verify saved Urgent state.";
        if (![saved respondsToSelector:@selector(urgentAlarmContext)]) return @"Native Urgent read context unavailable.";
        id savedContext = [saved urgentAlarmContext];
        if (![savedContext respondsToSelector:@selector(isUrgentStateEnabledForCurrentUser)]) return @"Native Urgent read API unavailable.";
        if ([savedContext isUrgentStateEnabledForCurrentUser] == urgent) return nil;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      }
      return @"Native Urgent write could not be verified.";
    } @catch (NSException *exception) {
      return [@"ReminderKit Urgent failed: " stringByAppendingString:exception.reason ?: exception.name];
    }
  }
}
