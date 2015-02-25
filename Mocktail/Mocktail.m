//
//  Mocktail.m
//  Mocktail
//
//  Created by Jim Puls on 2/7/13.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.
//

#import "Mocktail.h"
#import "Mocktail_Private.h"
#import "MocktailResponse.h"
#import "MocktailURLProtocol.h"


static NSString * const MocktailFileExtension = @".tail";



@interface Mocktail ()

@property (nonatomic, strong) NSMutableDictionary *mutablePlaceholderValues;
@property (nonatomic, strong) NSMutableSet *mutableMockResponses;
@property (nonatomic, strong) NSMutableDictionary *mutableMockResponsesInFolders;

@end


@implementation Mocktail

static NSMutableSet *_allMocktails;

+ (NSMutableSet *)allMocktails;
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _allMocktails = [NSMutableSet new];
    });
    
    return _allMocktails;
}

+ (instancetype)startWithContentsOfDirectoryAtURL:(NSURL *)url
{
    Mocktail *mocktail = [self new];
    [mocktail registerContentsOfDirectoryAtURL:url withTag:nil];
    [mocktail start];
    return mocktail;
}

- (id)init;
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _mutableMockResponses = [[NSMutableSet alloc] init];
    _mutableMockResponsesInFolders = [[NSMutableDictionary alloc] init];
    _mutablePlaceholderValues = [[NSMutableDictionary alloc] init];
    _networkDelay = 0.0;
    
    return self;
}

#pragma mark - Accessors/Mutators

- (NSDictionary *)placeholderValues;
{
    NSDictionary *placeholderValues;
    @synchronized (_mutablePlaceholderValues) {
        placeholderValues = [self.mutablePlaceholderValues copy];
    }
    return placeholderValues;
}

- (void)setObject:(id)object forKeyedSubscript:(id<NSCopying>)aKey
{
    @synchronized (_mutablePlaceholderValues) {
        [_mutablePlaceholderValues setObject:object forKey:aKey];
    }
}

- (id)objectForKeyedSubscript:(id<NSCopying>)aKey;
{
    NSString *value;
    @synchronized (_mutablePlaceholderValues) {
        value = [[_mutablePlaceholderValues objectForKey:aKey] copy];
    }
    return value;
}

- (NSSet *)mockResponses;
{
    NSSet *mockResponses;
    @synchronized (_mutableMockResponses) {
        mockResponses = [_mutableMockResponses copy];
    }
    return mockResponses;
}

- (NSSet*) responsesForTag:(NSString*)tag
{
    NSSet *mockResponses;
    @synchronized (_mutableMockResponsesInFolders) {
        if (_mutableMockResponsesInFolders[tag])
        {
            mockResponses = [_mutableMockResponsesInFolders[tag] copy];
        }
    }
    return mockResponses;
}

- (NSArray*) tagsMatchingQuery:(NSDictionary*)queries
{
    NSMutableArray* matchedTags = [NSMutableArray array];
    @synchronized (_mutableMockResponsesInFolders) {
        for(NSString* tag in _mutableMockResponsesInFolders.keyEnumerator)
        {
            NSDictionary* match = [self matchQuery:queries withTag:tag];
            if (match)
            {
                [matchedTags addObject:match];
            }
        }
    }
    return [matchedTags sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSDate *first = a[@"num_matches"];
        NSDate *second = b[@"num_matches"];
        return [second compare:first];
    }];;
}

- (NSDictionary*)matchQuery:(NSDictionary*)queries withTag:(NSString*)tag
{
    int matches = 0;
    for (NSString* keyString in queries.keyEnumerator)
    {
        NSString* val = queries[keyString];
        NSString* constructedTag = [NSString stringWithFormat:@"%@-%@/", [keyString lowercaseString], [val lowercaseString]];
        NSString* keySubTag = [NSString stringWithFormat:@"%@-", [keyString lowercaseString]];
        BOOL matchKey = [tag containsString:keySubTag];
        BOOL matchAll = [tag containsString:constructedTag];
        if (matchAll)
        {
            matches++;
        }
        else if (matchKey && !matchAll)
        {
            // Reject if this tag is not meant for the query, i.e. key matches, but value doesn't.
            return nil;
        }
    }
    if (matches > 0)
    {
        return @{
                 @"num_matches":@(matches),
                 @"tag":tag
                 };
    }
    else
    {
        return nil;
    }
}

+ (NSDictionary *)dictionaryFromUrlString:(NSString*)absoluteURL andQueryString:(NSString*)query
{
    NSMutableDictionary* dictionary = [NSMutableDictionary dictionary];
    NSArray* httpGetQueryParts = [absoluteURL componentsSeparatedByString:@"?"];
    if(httpGetQueryParts > 0)
    {
        for (NSUInteger i = 1; i < httpGetQueryParts.count ; i++) {
            [Mocktail transformStringToKeyValuePairs:httpGetQueryParts[i] andAddTo:dictionary];
        }
    }
    [Mocktail transformStringToKeyValuePairs:query andAddTo:dictionary];
    return dictionary;
}

+ (void)transformStringToKeyValuePairs:(NSString*)keyValuePairString andAddTo:(NSMutableDictionary*)dictionary
{
    NSArray* keyValuePairs = [keyValuePairString componentsSeparatedByString:@"&"];
    for(NSString* keyValue in keyValuePairs)
    {
        NSArray* kv = [keyValue componentsSeparatedByString:@"="];
        if(kv && kv.count >= 2)
        {
            dictionary[kv[0]] = kv[1];
        }
    }
}

+ (MocktailResponse *)mockResponseForURL:(NSURL *)url method:(NSString *)method requestBody:(NSData *)requestBody;
{
    NSAssert(url && method, @"Expected a valid URL and method.");
    
    NSString *requestBodyString = [[[NSString alloc] initWithData:requestBody encoding:NSUTF8StringEncoding] stringByRemovingPercentEncoding];

    NSString *absoluteURL = [url absoluteString];
    NSMutableSet* rootSet = [NSMutableSet set];
    for (Mocktail *mocktail in [Mocktail allMocktails]) {
        NSString *requestBodyStringWithScenario = nil;
        if(mocktail.scenarioHint)
        {
            requestBodyStringWithScenario = [NSString stringWithFormat:@"%@&%@=%@", requestBodyString, @"scenario", mocktail.scenarioHint];
        }
        else
        {
            requestBodyStringWithScenario = requestBodyString;
        }
        NSDictionary* queries = [Mocktail dictionaryFromUrlString:absoluteURL andQueryString:requestBodyStringWithScenario];
        // Find tags that match request params
        NSArray* tagsMatching = [mocktail tagsMatchingQuery:queries];
        for (NSDictionary* taggedFolder in tagsMatching)
        {
            NSString* tag = taggedFolder[@"tag"];
            NSSet* contentsForTag = [mocktail responsesForTag:tag];
            MocktailResponse * response = [Mocktail mostMatchingResponseInSet:contentsForTag forAbsoluteURLString:absoluteURL method:method requestBodyString:requestBodyStringWithScenario];
            if(response)
            {
                return response;
            }
        }
        [rootSet addObjectsFromArray:[mocktail.mutableMockResponses allObjects]];
    }
    
    return [Mocktail mostMatchingResponseInSet:rootSet forAbsoluteURLString:absoluteURL method:method requestBodyString:requestBodyString];
}

+ (MocktailResponse *)mostMatchingResponseInSet:(NSSet*)set forAbsoluteURLString:(NSString *)absoluteURL method:(NSString *)method requestBodyString:(NSString *)requestBodyString
{
    MocktailResponse *matchingResponse = nil;
    NSUInteger matchingRegexLength = 0;
    NSUInteger matchingBodyRegexLength = 0;
    
    for (MocktailResponse *response in set) {
        if ([response.absoluteURLRegex numberOfMatchesInString:absoluteURL options:0 range:NSMakeRange(0, absoluteURL.length)] > 0) {
            if ([response.methodRegex numberOfMatchesInString:method options:0 range:NSMakeRange(0, method.length)] > 0) {
                if (response.absoluteURLRegex.pattern.length >= matchingRegexLength) {
                    if ((response.requestBodyRegex == nil && matchingBodyRegexLength == 0) ||
                        (([response.requestBodyRegex numberOfMatchesInString:requestBodyString options:0 range:NSMakeRange(0, requestBodyString.length)] > 0) &&
                         response.requestBodyRegex.pattern.length >= matchingBodyRegexLength)) {
                            matchingResponse = response;
                            matchingRegexLength = response.absoluteURLRegex.pattern.length;
                            matchingBodyRegexLength = response.requestBodyRegex.pattern.length;
                        }
                }
            }
        }
    }
    return matchingResponse;
}


- (void)start;
{
    NSAssert([NSThread isMainThread], @"Please start and stop Mocktail from the main thread");
    NSAssert(![[Mocktail allMocktails] containsObject:self], @"Tried to start Mocktail twice");
    
    if ([Mocktail allMocktails].count == 0) {
        if (![NSURLProtocol registerClass:[MocktailURLProtocol class]])
        {
            NSAssert(NO, @"Unsuccessful Class Registration");
        }
    }
    [[Mocktail allMocktails] addObject:self];
}

- (void)stop;
{
    NSAssert([NSThread isMainThread], @"Please start and stop Mocktail from the main thread");
    NSAssert([[Mocktail allMocktails] containsObject:self], @"Tried to stop unstarted Mocktail");
    
    [[Mocktail allMocktails] removeObject:self];
    if ([Mocktail allMocktails].count == 0) {
        [NSURLProtocol unregisterClass:[MocktailURLProtocol class]];
    }
}

#pragma mark - Parsing files

- (BOOL)fileURLisDirectory:(NSURL*)url
{
    NSNumber *isDirectory;
    BOOL success = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    return success && [isDirectory boolValue];
}

- (void)registerContentsOfDirectoryAtURL:(NSURL *)url withTag:(NSString*)tag
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *fileURLs = [fileManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:0 error:&error];
    if (error) {
        NSLog(@"Error opening %@: %@", url, error);
        return;
    }
    
    for (NSURL *fileURL in fileURLs) {
        if([self fileURLisDirectory:fileURL] && ![[fileURL lastPathComponent] isEqualToString:@"Tails"])
        {
            NSString* fullURLStringOfParent = [url absoluteString];
            NSString* fullURLString = [fileURL absoluteString];
            NSString* derivedTagString = [[fullURLString substringFromIndex:fullURLStringOfParent.length] lowercaseString];
            NSString* concatenatedTagString = nil;
            if(!tag)
            {
                concatenatedTagString = derivedTagString;
            }
            else
            {
                concatenatedTagString = [NSString stringWithFormat:@"%@/%@", tag, derivedTagString];
            }
            [self registerContentsOfDirectoryAtURL:fileURL withTag:concatenatedTagString];
        }
        else if (![[fileURL absoluteString] hasSuffix:MocktailFileExtension]) {
            continue;
        }
        else
        {
            [self registerFileAtURL:fileURL withTag:tag];
        }
    }
}

- (void)registerFileAtURL:(NSURL *)url withTag:(NSString*)tag
{
    NSAssert(url, @"Expected valid URL.");
    
    NSError *error;
    NSStringEncoding originalEncoding;
    NSString *contentsOfFile = [NSString stringWithContentsOfURL:url usedEncoding:&originalEncoding error:&error];
    if (error) {
        NSLog(@"Error opening %@: %@", url, error);
        return;
    }
    
    NSScanner *scanner = [NSScanner scannerWithString:contentsOfFile];
    NSString *headerMatter = nil;
    [scanner scanUpToString:@"\n\n" intoString:&headerMatter];
    NSArray *lines = [headerMatter componentsSeparatedByString:@"\n"];
    if ([lines count] < 5) {
        NSLog(@"Invalid amount of lines: %u", (unsigned)[lines count]);
        return;
    }
    
    MocktailResponse *response = [MocktailResponse new];
    response.mocktail = self;
    response.methodRegex = [NSRegularExpression regularExpressionWithPattern:lines[0] options:NSRegularExpressionCaseInsensitive error:nil];
    response.absoluteURLRegex = [NSRegularExpression regularExpressionWithPattern:lines[1] options:NSRegularExpressionCaseInsensitive error:nil];
    if (![lines[2] isEqualToString:@"*"])
    {
        response.requestBodyRegex = [NSRegularExpression regularExpressionWithPattern:lines[2] options:NSRegularExpressionCaseInsensitive error:nil];
    }
    response.statusCode = [lines[3] integerValue];
    NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(4, lines.count - 4)]) {
        NSArray* parts = [line componentsSeparatedByString:@":"];
        [headers setObject:[[parts lastObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                    forKey:[parts firstObject]];
    }
    response.headers = headers;
    response.fileURL = url;
    response.bodyOffset = [headerMatter dataUsingEncoding:originalEncoding].length + 2;
    
    if(!tag || !tag.length)
    {
        @synchronized (_mutableMockResponses) {
            [_mutableMockResponses addObject:response];
        }
    }
    else
    {
        @synchronized (_mutableMockResponsesInFolders)
        {
            NSMutableArray* mutableArray = _mutableMockResponsesInFolders[tag];
            if(!mutableArray)
            {
                mutableArray = [NSMutableArray array];
            }
            [mutableArray addObject:response];
            _mutableMockResponsesInFolders[tag] = mutableArray;
        }
    }
}

@end
