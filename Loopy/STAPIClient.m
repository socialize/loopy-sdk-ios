//
//  STAPIClient.m
//  Loopy
//
//  Created by David Jedeikin on 9/10/13.
//  Copyright (c) 2013 ShareThis. All rights reserved.
//

#import "STAPIClient.h"
#import "STJSONUtils.h"
#import "STReachability.h"
#import <CommonCrypto/CommonDigest.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <AdSupport/ASIdentifierManager.h>
#import <sys/utsname.h>

@implementation STAPIClient

NSString *const INSTALL = @"/install";
NSString *const OPEN = @"/open";
NSString *const SHORTLINK = @"/shortlink";
NSString *const REPORT_SHARE = @"/share";
NSString *const SHARELINK = @"/sharelink";
NSString *const LOG = @"/log";

NSString *const API_KEY = @"X-LoopyAppID";
NSString *const LOOPY_KEY = @"X-LoopyKey";
NSString *const STDID_KEY = @"stdid";
NSString *const MD5ID_KEY = @"md5id";
NSString *const LAST_OPEN_TIME_KEY = @"lastOpenTime";
NSString *const LANGUAGE_ID = @"objc";
NSString *const LANGUAGE_VERSION = @"1.3";
NSString *const SESSION_DATA_FILENAME = @"STSessionData.plist";

@synthesize callTimeout = _callTimeout;
@synthesize openTimeout = _openTimeout;
@synthesize urlPrefix;
@synthesize httpsURLPrefix;
@synthesize apiKey;
@synthesize loopyKey;
@synthesize locationManager;
@synthesize carrierName;
@synthesize osVersion;
@synthesize deviceModel;
@synthesize stdid;
@synthesize md5id;
@synthesize idfa;
@synthesize currentLocation;
@synthesize shortlinks;

//constructor with specified endpoint
//performs actions to check for stdid and calls "install" or "open" as required
- (id)initWithAPIKey:(NSString *)key
            loopyKey:(NSString *)lkey {
    self = [super init];
    if(self) {
        //init shortlink cache
        self.shortlinks = [NSMutableDictionary dictionary];
        
        //set keys
        self.apiKey = key;
        self.loopyKey = lkey;
        
        //set URLs
        NSBundle *bundle =  [NSBundle bundleForClass:[self class]];
        NSString *configPath = [bundle pathForResource:@"LoopyApiInfo" ofType:@"plist"];
        NSDictionary *configurationDict = [[NSDictionary alloc]initWithContentsOfFile:configPath];
        NSDictionary *apiInfoDict = [configurationDict objectForKey:@"Loopy API info"];
        self.urlPrefix = [apiInfoDict objectForKey:@"urlPrefix"];
        self.httpsURLPrefix = [apiInfoDict objectForKey:@"urlHttpsPrefix"];
        
        //set timeouts
        NSNumber *callTimeoutMillis = [apiInfoDict objectForKey:@"callTimeoutInMillis"];
        NSNumber *openTimeoutMillis = [apiInfoDict objectForKey:@"openTimeoutInMillis"];
        _callTimeout = [callTimeoutMillis floatValue] / 1000.0f;
        _openTimeout = [openTimeoutMillis floatValue] / 1000.0f;
        
        //device information cached for sharing and other operations
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        self.locationManager.delegate = self;
        [self.locationManager startUpdatingLocation];
        CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
        CTCarrier *carrier = [networkInfo subscriberCellularProvider];
        UIDevice *device = [UIDevice currentDevice];
        self.carrierName = [carrier carrierName] != nil ? [carrier carrierName] : @"none";
        self.deviceModel = machineName();
        self.osVersion = device.systemVersion;
        
        //md5 hash of IDFA
        //IDFA is cached for dependency injection purposes
        ASIdentifierManager *idManager = [ASIdentifierManager sharedManager];
        self.idfa = idManager.advertisingIdentifier;
        if(self.idfa) {
            self.md5id = [self md5FromString:[self.idfa UUIDString]];
        }
    }
    return self;
}

#pragma mark - Identities Handling

//creates/loads session file from disk, and calls appropriate recording endpoint (/open or /install) as required
- (void)getSessionWithReferrer:(NSString *)referrer
                   postSuccess:(void(^)(AFHTTPRequestOperation *, id))postSuccessCallback
                       failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    NSString *rootPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *filePath = [rootPath stringByAppendingPathComponent:SESSION_DATA_FILENAME];
    NSMutableDictionary *plistDict = [[NSMutableDictionary alloc] initWithContentsOfFile:filePath];
    NSDate *now = [NSDate date];
    NSNumber *nowNum = [NSNumber numberWithDouble:[now timeIntervalSince1970]];
    NSString *error = nil;
    NSData *plistData = nil;
    
    //no file -- call /install and store device-generated stdid in new file
    if(!plistDict) {
        NSUUID *stdidObj = (NSUUID *)[NSUUID UUID];
        self.stdid = (NSString *)[stdidObj UUIDString];
        NSMutableDictionary *newPlistDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                             self.stdid,STDID_KEY,
                                             nowNum,LAST_OPEN_TIME_KEY,
                                             nil];
        plistData = [NSPropertyListSerialization dataFromPropertyList:(id)newPlistDict
                                                               format:NSPropertyListXMLFormat_v1_0
                                                     errorDescription:&error];
        [plistData writeToFile:filePath atomically:YES];
        
        [self install:[self installDictionaryWithReferrer:referrer]
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  if(postSuccessCallback != nil) {
                      postSuccessCallback(operation, responseObject);
                  }
              }
              failure:failureCallback];
    }
    //file exists -- call /open with stdid from file if timeout has been hit
    //store updated timestamp in file if new open needs to be called
    else {
        self.stdid = (NSString *)[plistDict valueForKey:STDID_KEY];
        NSNumber *lastOpenNum = (NSNumber *)[plistDict valueForKey:LAST_OPEN_TIME_KEY];
        double diff = [nowNum doubleValue] - [lastOpenNum doubleValue];
        
        if(diff > _openTimeout) {
            plistData = [NSPropertyListSerialization dataFromPropertyList:(id)plistDict
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                         errorDescription:&error];
            [plistData writeToFile:filePath atomically:YES];
            
            [self open:[self openDictionaryWithReferrer:referrer]
               success:^(AFHTTPRequestOperation *operation, id responseObject) {
                   if(postSuccessCallback != nil) {
                       postSuccessCallback(operation, responseObject);
                   }
               }
               failure:failureCallback];
        }
        //bogus call to success to indicating no open needed
        else {
            if(postSuccessCallback != nil) {
                postSuccessCallback(nil, nil);
            }
        }
    }
}

#pragma mark - URL Requests

//factory method for URLRequest for specified JSON data and endpoint
- (NSMutableURLRequest *)newHTTPSURLRequest:(NSData *)jsonData
                                     length:(NSNumber *)length
                                   endpoint:(NSString *)endpoint {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", httpsURLPrefix, endpoint];
    return [self jsonURLRequestForURL:urlStr data:jsonData length:length];
}

//factory method for URLRequest for specified JSON data and endpoint
- (NSMutableURLRequest *)newURLRequest:(NSData *)jsonData
                                length:(NSNumber *)length
                              endpoint:(NSString *)endpoint {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", urlPrefix, endpoint];
    return [self jsonURLRequestForURL:urlStr data:jsonData length:length];
}

//convenience method
-(NSMutableURLRequest *)jsonURLRequestForURL:(NSString *)urlStr
                                        data:(NSData *)jsonData
                                      length:(NSNumber *)length {
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:_callTimeout];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.apiKey forHTTPHeaderField:API_KEY];
    [request setValue:self.loopyKey forHTTPHeaderField:LOOPY_KEY];
    [request setValue:[length stringValue] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:jsonData];
    
    return request;
}

//factory method to init operations with specified requests and callbacks
- (AFHTTPRequestOperation *)newURLRequestOperation:(NSURLRequest *)request
                                           isHTTPS:(BOOL)https
                                           success:(void(^)(AFHTTPRequestOperation *, id))successCallback
                                           failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];
    [operation setCompletionBlockWithSuccess:successCallback
                                     failure:failureCallback];
    
    //allow self-signed certs for HTTPS
    if(https) {
        [operation setWillSendRequestForAuthenticationChallengeBlock:^(NSURLConnection *connection, NSURLAuthenticationChallenge *challenge) {
            SecTrustRef trust = challenge.protectionSpace.serverTrust;
            NSURLCredential *cred = [NSURLCredential credentialForTrust:trust];
            [challenge.sender useCredential:cred forAuthenticationChallenge:challenge];
            [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
        }];
    }
    return operation;
}

//Returns error code
//if code is nil or no error value contained, returns nil
- (NSNumber *)loopyErrorCode:(NSDictionary *)errorDict {
    NSNumber *errorCode = nil;
    id codeObj = [errorDict valueForKey:@"code"];
    if([codeObj isKindOfClass:[NSNumber class]]) {
        errorCode = (NSNumber *)codeObj;
    }
    return errorCode;
}

//Returns array of error values taken from the userInfo portion of error returned from request
//if error is nil or no error value contained, returns nil
- (NSArray *)loopyErrorArray:(NSDictionary *)errorDict {
    NSArray *errorArray = nil;
    id errorObj = [errorDict valueForKey:@"error"];
    
    if([errorObj isKindOfClass:[NSArray class]]) {
        errorArray = (NSArray *)errorObj;
    }
    return errorArray;
}

#pragma mark - JSON For Endpoints

//returns JSON-ready dictionary for /install endpoint for specified referrer
- (NSDictionary *)installDictionaryWithReferrer:(NSString *)referrer {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    
    //add IDFA to device dictionary -- install only
    NSMutableDictionary *deviceObj = [NSMutableDictionary dictionaryWithDictionary:[self deviceDictionary]];
    [deviceObj setObject:[self.idfa UUIDString] forKey:@"id"];
    
    NSDictionary *installObj = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithInt:timestamp],@"timestamp",
                                referrer,@"referrer",
                                self.stdid, @"stdid",
                                self.md5id, @"md5id",
                                deviceObj,@"device",
                                [self appDictionary],@"app",
                                [self clientDictionary],@"client",
                                nil];
    return installObj;
}

//returns JSON-ready dictionary for /open endpoint for specified referrer
- (NSDictionary *)openDictionaryWithReferrer:(NSString *)referrer {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    NSDictionary *openObj = [NSDictionary dictionaryWithObjectsAndKeys:
                             self.stdid,@"stdid",
                             self.md5id, @"md5id",
                             [NSNumber numberWithInt:timestamp],@"timestamp",
                             referrer,@"referrer",
                             [self deviceDictionary],@"device",
                             [self appDictionary],@"app",
                             [self clientDictionary],@"client",
                             nil];
    return openObj;
}

//returns JSON-ready dictionary for /share endpoint, based on shortlink and channel
- (NSDictionary *)reportShareDictionary:(NSString *)shortlink channel:(NSString *)socialChannel {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    NSDictionary *shareObj = [NSDictionary dictionaryWithObjectsAndKeys:
                              self.stdid,@"stdid",
                              self.md5id, @"md5id",
                              [NSNumber numberWithInt:timestamp],@"timestamp",
                              [self deviceDictionary],@"device",
                              [self appDictionary],@"app",
                              socialChannel,@"channel",
                              shortlink,@"shortlink",
                              [self clientDictionary],@"client",
                              nil];
    
    return shareObj;
}

//returns JSON-ready dictionary for /sharelink endpoint
- (NSDictionary *)sharelinkDictionary:(NSString *)link
                              channel:(NSString *)socialChannel
                                title:(NSString *)title
                                 meta:(NSDictionary *)meta
                                 tags:(NSArray *)tags {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *itemObj = [NSMutableDictionary dictionary];
    if(link != nil) {
        [itemObj setValue:link forKey:@"url"];
    }
    if(title != nil) {
        [itemObj setValue:title forKey:@"title"];
    }
    if(meta != nil) {
        [itemObj setValue:meta forKey:@"meta"];
    }
    NSMutableDictionary *sharelinkObj = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         self.stdid,@"stdid",
                                         self.md5id, @"md5id",
                                         [NSNumber numberWithInt:timestamp],@"timestamp",
                                         [self deviceDictionary],@"device",
                                         [self appDictionary],@"app",
                                         socialChannel,@"channel",
                                         [self clientDictionary],@"client",
                                         itemObj,@"item",
                                         nil];
    
    if(tags != nil) {
        [sharelinkObj setValue:tags forKey:@"tags"];
    }

    return sharelinkObj;
}

//returns JSON-ready dictionary for /log endpoint, based on type and meta
- (NSDictionary *)logDictionaryWithType:(NSString *)type meta:(NSDictionary *)meta {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    NSDictionary *eventObj = [NSDictionary dictionaryWithObjectsAndKeys:
                              type,@"type",
                              meta,@"meta",
                              nil];
    NSDictionary *logObj = [NSDictionary dictionaryWithObjectsAndKeys:
                            self.stdid,@"stdid",
                            self.md5id, @"md5id",
                            [NSNumber numberWithInt:timestamp],@"timestamp",
                            [self deviceDictionary],@"device",
                            [self appDictionary],@"app",
                            [self clientDictionary],@"client",
                            eventObj,@"event",
                            nil];
    
    return logObj;
}

//returns JSON-ready dictionary for /shortlink endpoint, based on link, title, meta, and tags
//Either link OR title may be nil, but not both
//Meta may be nil, or may contain various OG keys
- (NSDictionary *)shortlinkDictionary:(NSString *)link
                                title:(NSString *)title
                                 meta:(NSDictionary *)meta
                                 tags:(NSArray *)tags {
    int timestamp = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *itemObj = [NSMutableDictionary dictionary];
    if(link != nil) {
        [itemObj setValue:link forKey:@"url"];
    }
    if(title != nil) {
        [itemObj setValue:title forKey:@"title"];
    }
    if(meta != nil) {
        [itemObj setValue:meta forKey:@"meta"];
    }
    NSMutableDictionary *shortlinkObj = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         self.stdid,@"stdid",
                                         self.md5id, @"md5id",
                                         [NSNumber numberWithInt:timestamp],@"timestamp",
                                         itemObj,@"item",
                                         nil];
    if(tags != nil) {
        [shortlinkObj setValue:tags forKey:@"tags"];
    }
    
    return shortlinkObj;
}

//required subset of endpoint calls
- (NSDictionary *)deviceDictionary {
    CLLocationCoordinate2D coordinate;
    STReachability *reachability = [STReachability reachabilityForInternetConnection];
    NetworkStatus netStatus = [reachability currentReachabilityStatus];
    NSString *wifiStatus = netStatus == ReachableViaWiFi ? @"on" : @"off";
    NSMutableDictionary *deviceObj = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                      self.deviceModel,@"model",
                                      @"ios",@"os",
                                      self.osVersion,@"osv",
                                      self.carrierName,@"carrier",
                                      wifiStatus,@"wifi",
                                      nil];
    NSDictionary *geoObj = nil;
    if(self.currentLocation) {
        coordinate = self.currentLocation.coordinate;
        geoObj = [NSDictionary dictionaryWithObjectsAndKeys:
                  [NSNumber numberWithDouble:coordinate.latitude],@"lat",
                  [NSNumber numberWithDouble:coordinate.longitude],@"lon",
                  nil];
        [deviceObj setObject:geoObj forKey:@"geo"];
    }
    
    return deviceObj;
}

//required subset of endpoint calls
- (NSDictionary *)appDictionary {
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = [bundle infoDictionary];
    NSString *appID = [info valueForKey:@"CFBundleIdentifier"];
    NSString *appName = [info valueForKey:@"CFBundleName"];
    NSString *appVersion = [info valueForKey:@"CFBundleVersion"];
    NSDictionary *appObj = [NSDictionary dictionaryWithObjectsAndKeys:
                            appID,@"id",
                            appName,@"name",
                            appVersion,@"version",
                            nil];
    return appObj;
}

//required subset of endpoint calls
- (NSDictionary *)clientDictionary {
    NSDictionary *clientObj = [NSDictionary dictionaryWithObjectsAndKeys:
                               LANGUAGE_ID,@"lang",
                               LANGUAGE_VERSION,@"version",
                               nil];
    return clientObj;
}

#pragma mark - Calling Endpoints

- (void)install:(NSDictionary *)jsonDict
        success:(void(^)(AFHTTPRequestOperation *, id))successCallback
        failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    [self callHTTPSEndpoint:INSTALL json:jsonDict success:successCallback failure:failureCallback];
}

- (void)open:(NSDictionary *)jsonDict
     success:(void(^)(AFHTTPRequestOperation *, id))successCallback
     failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    [self callEndpoint:OPEN json:jsonDict success:successCallback failure:failureCallback];
}

- (void)shortlink:(NSDictionary *)jsonDict
          success:(void(^)(AFHTTPRequestOperation *, id))successCallback
          failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    //check the cache to see if shortlink already exists, and if so, simply call successCallback
    NSDictionary *item = (NSDictionary *)[jsonDict valueForKey:@"item"];
    NSString *url = (NSString *)[item valueForKey:@"url"];
    if([self.shortlinks valueForKey:url]) {
        NSDictionary *shortlinkDict = [NSDictionary dictionaryWithObjectsAndKeys:[self.shortlinks valueForKey:url], @"shortlink", nil];
        successCallback(nil, shortlinkDict);
    }
    else {
        [self callEndpoint:SHORTLINK
                      json:jsonDict
                   success:^(AFHTTPRequestOperation *operation, id responseObject) {
                       //cache the shortlink for future reuse
                       NSDictionary *responseDict = (NSDictionary *)responseObject;
                       [self.shortlinks setValue:[responseDict valueForKey:@"shortlink"] forKey:url];
                       if(successCallback != nil) {
                           successCallback(operation, responseObject);
                       }
                   }
                   failure:failureCallback];
    }
}

- (void)reportShare:(NSDictionary *)jsonDict
            success:(void(^)(AFHTTPRequestOperation *, id))successCallback
            failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    [self callEndpoint:REPORT_SHARE
                  json:jsonDict
               success:^(AFHTTPRequestOperation *operation, id responseObject) {
                   //remove current shortlink from cache
                   //although shortlinks are the values (not keys) of the shortlinks dictionary, they should be unique
                   //thus keys should contain only one element
                   NSString *shortlink = (NSString *)[jsonDict objectForKey:@"shortlink"];
                   NSArray *keys = [self.shortlinks allKeysForObject:shortlink];
                   for(id key in keys) {
                       [self.shortlinks removeObjectForKey:key];
                   }
                   if(successCallback != nil) {
                       successCallback(operation, responseObject);
                   }
               }
               failure:failureCallback];
}
- (void)sharelink:(NSDictionary *)jsonDict
          success:(void(^)(AFHTTPRequestOperation *, id))successCallback
          failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    [self callEndpoint:SHARELINK
                  json:jsonDict
               success:^(AFHTTPRequestOperation *operation, id responseObject) {
                   //remove current shortlink from cache
                   //although shortlinks are the values (not keys) of the shortlinks dictionary, they should be unique
                   //thus keys should contain only one element
                   NSString *shortlink = (NSString *)[jsonDict objectForKey:@"shortlink"];
                   NSArray *keys = [self.shortlinks allKeysForObject:shortlink];
                   for(id key in keys) {
                       [self.shortlinks removeObjectForKey:key];
                   }
                   if(successCallback != nil) {
                       successCallback(operation, responseObject);
                   }
               }
               failure:failureCallback];
}

- (void)log:(NSDictionary *)jsonDict
    success:(void(^)(AFHTTPRequestOperation *, id))successCallback
    failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    [self callEndpoint:LOG json:jsonDict success:successCallback failure:failureCallback];
}

//convenience method
- (void)callHTTPSEndpoint:(NSString *)endpoint
                     json:(NSDictionary *)jsonDict
                  success:(void(^)(AFHTTPRequestOperation *, id))successCallback
                  failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    NSData *jsonData = [STJSONUtils toJSONData:jsonDict];
    NSString *jsonStr = [STJSONUtils toJSONString:jsonData];
    NSNumber *jsonLength = [NSNumber numberWithInt:[jsonStr length]];
    NSURLRequest *request = [self newHTTPSURLRequest:jsonData
                                              length:jsonLength
                                            endpoint:endpoint];
    AFHTTPRequestOperation *operation = [self newURLRequestOperation:request
                                                             isHTTPS:NO //TEMPORARY
                                                             success:successCallback
                                                             failure:failureCallback];
    [operation start];
}

//convenience method
- (void)callEndpoint:(NSString *)endpoint
                json:(NSDictionary *)jsonDict
             success:(void(^)(AFHTTPRequestOperation *, id))successCallback
             failure:(void(^)(AFHTTPRequestOperation *, NSError *))failureCallback {
    NSData *jsonData = [STJSONUtils toJSONData:jsonDict];
    NSString *jsonStr = [STJSONUtils toJSONString:jsonData];
    NSNumber *jsonLength = [NSNumber numberWithInt:[jsonStr length]];
    NSURLRequest *request = [self newURLRequest:jsonData
                                         length:jsonLength
                                       endpoint:endpoint];
    AFHTTPRequestOperation *operation = [self newURLRequestOperation:request
                                                             isHTTPS:NO
                                                             success:successCallback
                                                             failure:failureCallback];
    [operation start];
}

#pragma mark - Location And Device Information

//location update
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    if(locations.lastObject) {
        currentLocation = (CLLocation *)locations.lastObject;
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

//convenience method to return MD% String
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
