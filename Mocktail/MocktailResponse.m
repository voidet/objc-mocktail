//
//  MocktailResponse.m
//  Mocktail
//
//  Created by Matthias Plappert on 3/11/13.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.
//

#import "MocktailResponse.h"


@implementation MocktailResponse

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@> {\n\tfile = %@ \n\tmethod = %@\n\t url = %@\n\t body = %@\n}",
            NSStringFromClass([self class]),
            [self fileURL],
            [self methodRegex],
            [self absoluteURLRegex],
            [self requestBodyRegex]];
}

@end

