//
//  SZAPIClient.h
//  Loopy
//
//  Created by David Jedeikin on 9/10/13.
//  Copyright (c) 2013 ShareThis. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SZAPIClient : NSObject

@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSString *urlPrefix;
//@property (nonatomic, strong) NSURLConnection *connection;

- (id)initWithURLPrefix:(NSString *)url;
- (void)open:(NSDictionary *)openJSON withDelegate:(id)delegate;
@end
