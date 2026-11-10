#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Native Early Reminder is separate from EventKit alarms. nil means success.
FOUNDATION_EXPORT BOOL ReminderKitEarlyReminderAvailable(void);
FOUNDATION_EXPORT NSString * _Nullable ReminderKitSetEarlyReminder(NSString *identifier, NSInteger minutes, BOOL clear);
NS_ASSUME_NONNULL_END
