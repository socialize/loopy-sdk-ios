//
//  STDeviceSettings.h
//  Loopy
//
//  Created by David Jedeikin on 4/15/14.
//  Copyright (c) 2014 ShareThis. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <AdSupport/ASIdentifierManager.h>
#import <sys/utsname.h>

@interface STDeviceSettings : NSObject<CLLocationManagerDelegate>

@property (nonatomic, strong) NSString *md5id;
@property (nonatomic, strong) NSUUID *idfa;
@property (nonatomic, strong) CLLocation *currentLocation;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) NSString *carrierName;
@property (nonatomic, strong) NSString *osVersion;
@property (nonatomic, strong) NSString *deviceModel;

- (id)initWithLocationsDisabled:(BOOL)locationServicesDisabled;
- (NSDictionary *)deviceDictionary;
- (NSDictionary *)appDictionary;
- (NSString *)md5FromString:(NSString *)input;

@end