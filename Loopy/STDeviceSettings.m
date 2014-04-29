//
//  STDeviceSettings.m
//  Loopy
//
//  Created by David Jedeikin on 4/15/14.
//  Copyright (c) 2014 ShareThis. All rights reserved.
//

#import "STDeviceSettings.h"
#import "STReachability.h"
#import "STDevice.h"
#import "STApp.h"
#import "STGeo.h"

//set to 1 to use it, 0 to use generic UUID that's cached
#define SHOULD_USE_IDFA 0

@implementation STDeviceSettings

NSString *const DEVICE_DATA_FILENAME = @"STDeviceData.plist";
NSString *const DEVICE_ID_KEY = @"DeviceID";

@synthesize locationManager;
@synthesize carrierName;
@synthesize osVersion;
@synthesize deviceModel;
@synthesize md5id;
@synthesize idfa;
@synthesize currentLocation;

- (id)initWithLocationsDisabled:(BOOL)locationServicesDisabled {
    self = [super init];
    
    if(self) {
        //device information cached for sharing and other operations
        if(!locationServicesDisabled) {
            self.locationManager = [[CLLocationManager alloc] init];
            self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
            self.locationManager.delegate = self;
            [self.locationManager startUpdatingLocation];
        }
        CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
        CTCarrier *carrier = [networkInfo subscriberCellularProvider];
        UIDevice *device = [UIDevice currentDevice];
        self.carrierName = [carrier carrierName] != nil ? [carrier carrierName] : @"none";
        self.deviceModel = machineName();
        self.osVersion = device.systemVersion;
        
        //md5 hash of IDFA
        //IDFA is cached for dependency injection purposes
        //conditional code for compliance purposes as Apple does not permit apps that don't serve ads to use IDFA
#if SHOULD_USE_IDFA
        ASIdentifierManager *idManager = [ASIdentifierManager sharedManager];
        self.idfa = idManager.advertisingIdentifier;
#else
        NSString *rootPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
        NSString *filePath = [rootPath stringByAppendingPathComponent:DEVICE_DATA_FILENAME];
        NSMutableDictionary *plistDict = [[NSMutableDictionary alloc] initWithContentsOfFile:filePath];

        //no file -- create stdid
        if(!plistDict) {
            self.idfa = (NSUUID *)[NSUUID UUID];
            plistDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                                 [self.idfa UUIDString],DEVICE_ID_KEY,
                                                 nil];
            [plistDict writeToFile:filePath atomically:YES];
        }
        //file exists -- read it and use ID
        else {
            NSString *idfaString = (NSString *)[plistDict objectForKey:DEVICE_ID_KEY];
            self.idfa = [[NSUUID alloc] initWithUUIDString:idfaString];
        }
#endif
        
        if(self.idfa) {
            self.md5id = [self md5FromString:[self.idfa UUIDString]];
        }
        //for headless devices
        else {
            self.idfa = [NSUUID UUID];
            self.md5id = [self md5FromString:[self.idfa UUIDString]];
        }
    }
    return self;
}

//required subset of endpoint calls
- (STDevice *)device {
    CLLocationCoordinate2D coordinate;
    STReachability *reachability = [STReachability reachabilityForInternetConnection];
    NetworkStatus netStatus = [reachability currentReachabilityStatus];
    NSString *wifiStatus = netStatus == ReachableViaWiFi ? @"on" : @"off";
    NSString *idStr = [self.idfa UUIDString];
    
    STDevice *device = [[STDevice alloc] init];
    device.id = idStr;
    device.model = self.deviceModel;
    device.os = @"ios";
    device.osv = self.osVersion;
    device.carrier = self.carrierName;
    device.wifi = wifiStatus;
    
    STGeo *geo = nil;
    if(self.currentLocation) {
        coordinate = self.currentLocation.coordinate;
    }
    //location management disabled; simply set to 0,0
    else {
        coordinate = CLLocationCoordinate2DMake(0.0, 0.0);
    }
    geo = [[STGeo alloc] init];
    geo.lat = [NSNumber numberWithDouble:coordinate.latitude];
    geo.lon = [NSNumber numberWithDouble:coordinate.longitude];
    device.geo = geo;
    
    return device;
}

//required subset of endpoint calls
- (STApp *)app {
    STApp *app = [[STApp alloc] init];
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];
    NSString *appID = [info valueForKey:@"CFBundleIdentifier"];
    NSString *appName = [info valueForKey:@"CFBundleName"];
    NSString *appVersion = [info valueForKey:@"CFBundleVersion"];
    
    app.id = appID;
    app.name = appName;
    app.version = appVersion;
    
    return app;
}

#pragma mark - Location And Device Information

//location update
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    if(locations.lastObject) {
        self.currentLocation = (CLLocation *)locations.lastObject;
    }
}

//convenience method to return "real" device name
//per http://stackoverflow.com/questions/11197509/ios-iphone-get-device-model-and-make
NSString *machineName() {
    struct utsname systemInfo;
    uname(&systemInfo);
    
    return [NSString stringWithCString:systemInfo.machine
                              encoding:NSUTF8StringEncoding];
}

//convenience method to return MD5 String
//per http://www.makebetterthings.com/iphone/how-to-get-md5-and-sha1-in-objective-c-ios-sdk/
- (NSString *)md5FromString:(NSString *)input {
    const char *cStr = [input UTF8String];
    unsigned char digest[16];
    CC_MD5( cStr, strlen(cStr), digest ); // This is the md5 call
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    
    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

@end
