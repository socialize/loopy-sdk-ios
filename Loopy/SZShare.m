//
//  SZShare.m
//  Loopy
//
//  Created by David Jedeikin on 10/23/13.
//  Copyright (c) 2013 ShareThis. All rights reserved.
//

#import "SZShare.h"
#import "SZActivity.h"
#import "SZFacebookActivity.h"
#import "SZTwitterActivity.h"
#import "SZConstants.h"

@implementation SZShare

@synthesize parentController;
@synthesize apiClient;

- (id)initWithParent:(UIViewController *)parent apiClient:(SZAPIClient *)client {
    self = [super init];
    if(self) {
        self.parentController = parent;
        self.apiClient = client;
        //listen for share events (both intent to share -- beginning -- and end -- share complete)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleShowActivityShare:)
                                                     name:BeginShareNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleShareComplete:)
                                                     name:EndShareNotification
                                                   object:nil];
    }
    
    return self;
}

//Returns the default set of Activities using the specified activity items
//These are newly-created each time as activities will vary
- (NSArray *)getDefaultActivities:(NSArray *)activityItems {
    SZFacebookActivity *fbActivity = [[SZFacebookActivity alloc] init];
    SZTwitterActivity *twitterActivity = [[SZTwitterActivity alloc] init];
    
    return @[fbActivity, twitterActivity];
}

//Returns UIActivityViewController for specified items and activities
//This is the ViewController to SELECT Activity (i.e. social network) to share
- (UIActivityViewController *)newActivityViewController:(NSArray *)shareItems withActivities:(NSArray *)activities {
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:shareItems
                                                                                         applicationActivities:activities];
    activityViewController.excludedActivityTypes = @[UIActivityTypePostToFacebook,
                                                     UIActivityTypePostToTwitter,
                                                     UIActivityTypePostToWeibo,
                                                     UIActivityTypeMail,
                                                     UIActivityTypeCopyToPasteboard];
    return activityViewController;
}

//Returns SLComposeViewController with specified activity items for specified service type
//The is the view controller to share the activity items to a specified social network
//TODO for now simply assumes first activity item is a NSString shortlink
- (SLComposeViewController *)newActivityShareController:(id)activityObj {
    NSString *slServiceType = nil;
    NSArray *activityItems = nil;
    SLComposeViewController *controller = nil;
    
    if([[activityObj class] conformsToProtocol:@protocol(SZActivity)]) {
        id<SZActivity> activity = (id<SZActivity>)activityObj;
        activityItems = [activity shareItems];
        slServiceType = [activity activityType];
    }

    controller = [SLComposeViewController composeViewControllerForServiceType:slServiceType];
    if([activityItems count] > 0) {
        id firstItem = [activityItems objectAtIndex:0];
        if([firstItem isKindOfClass:[NSString class]]) {
            NSString *shareMessage = [NSString stringWithFormat:@"Check out this link: %@", (NSString *)firstItem];
            [controller setInitialText:shareMessage];
        }
    }
    
    return controller;
}

#pragma mark - UI operations

//Shows main share selector dialog
- (void)showActivityViewDialog:(UIActivityViewController *)activityController completion:(void (^)(void))completion {
    [self.parentController presentViewController:activityController animated:YES completion:completion];
}

//Shows specific share dialog for selected service
- (void)handleShowActivityShare:(NSNotification *)notification {
    __block id<SZActivity> activity = (id<SZActivity>)[notification object];
    //dismiss share selector and bring up activity-specific share dialog
    [self.parentController dismissViewControllerAnimated:YES completion:^ {
        SLComposeViewController *controller = [self newActivityShareController:activity];
        controller.completionHandler = ^(SLComposeViewControllerResult result) {
            switch(result) {
                case SLComposeViewControllerResultCancelled:
                    break;
                //post notification of share
                //this is done as a callback as implementors may post notification as well
                case SLComposeViewControllerResultDone:
                    [[NSNotificationCenter defaultCenter] postNotificationName:EndShareNotification object:activity];
                    break;
            }
        };
        [self.parentController presentViewController:controller animated:YES completion:nil];
    }];
}

//calls out to API to report share
- (void)handleShareComplete:(NSNotification *)notification {
    id<SZActivity> activity = (id<SZActivity>)[notification object];
    NSArray *shareItems = activity.shareItems;
    NSString *shareItem = (NSString *)[shareItems lastObject]; //by default last item is the shortlink or other share item
    NSDictionary *shareDict = [self.apiClient reportShareDictionary:shareItem
                                                            channel:activity.activityType];
    [self.apiClient reportShare:shareDict
                        success:^(AFHTTPRequestOperation *operation, id responseObject) {
                            //Currently no response is needed after success
                        }
                        failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                            //Currently no response is made after failure; this may change
                        }];

}

@end
