//
//  SPImage.m
//  CocoaLibSpotify
//
//  Created by Daniel Kennett on 2/20/11.
/*
Copyright (c) 2011, Spotify AB
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Spotify AB nor the names of its contributors may 
      be used to endorse or promote products derived from this software 
      without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL SPOTIFY AB BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, 
OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "SPImage.h"
#import "SPSession.h"
#import "SPURLExtensions.h"

static NSCache *g_imageCache;

@interface SPImageCallbackProxy : NSObject

// SPImageCallbackProxy is here to bridge the gap between -dealloc and the
// playlist callbacks being unregistered, since that's done async.
@property (nonatomic, readwrite, assign) __unsafe_unretained SPImage *image;

@end

@implementation SPImageCallbackProxy

@end

@interface SPImage ()

@property (nonatomic, readwrite, strong) SPPlatformNativeImage *image;
@property (nonatomic, readwrite) sp_image *spImage;
@property (nonatomic, readwrite, getter=isLoaded) BOOL loaded;
@property (nonatomic, readwrite, copy) NSURL *spotifyURL;
@property (nonatomic, readwrite, strong) SPImageCallbackProxy *callbackProxy;

@end

#pragma mark - LibSpotify

static SPPlatformNativeImage *create_native_image(sp_image *image)
{
    SPCAssertOnLibSpotifyThread();
    
    size_t size = 0;
    const byte *data = sp_image_data(image, &size);
    
    if (size == 0) {
        return nil;
    }
    
    return [[SPPlatformNativeImage alloc] initWithData:[NSData dataWithBytes:data length:size]];
}

static NSURL *create_image_url(sp_image *image)
{
    SPCAssertOnLibSpotifyThread();
    
    sp_link *link = sp_link_create_from_image(image);
    if (link == NULL) {
        return nil;
    }
    
    NSURL *url = [NSURL urlWithSpotifyLink:link];
    sp_link_release(link);

    return url;
}

static void image_loaded(sp_image *image, void *userdata)
{
	SPImageCallbackProxy *proxy = (__bridge SPImageCallbackProxy *)userdata;
	if (!proxy.image) {
        return;
    }
	
	BOOL isLoaded = sp_image_is_loaded(image);

	SPPlatformNativeImage *im = nil;
	if (isLoaded) {
        im = create_native_image(proxy.image.spImage);
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		proxy.image.image = im;
		proxy.image.loaded = isLoaded;
	});
}

/// This is a hack. There is no supported method to go directly from an
/// image id to a spotify url. However, the unique portion of the url
/// appears to be the image id encoded as a hex string.
static NSURL *create_url_from_image_id(NSData *image_id)
{
    const NSUInteger length = image_id.length;
    const char *bytes = image_id.bytes;
    
    NSMutableString *str = [NSMutableString stringWithString:@"spotify:image:"];
    for (NSUInteger i = 0; i < length; i++) {
        [str appendFormat:@"%02hhx", bytes[i]];
    }

    return [[NSURL alloc] initWithString:str];
}

#pragma mark - SPImage

@implementation SPImage {
	BOOL _hasStartedLoading;
}

+ (void)initialize
{
    if (self == [SPImage class]) {
        g_imageCache = [[NSCache alloc] init];
    }
}

+ (NSData *)cacheKeyFromImageId:(const byte *)imageId
{
    return [NSData dataWithBytes:imageId length:SPImageIdLength];;
}

+ (void)createLinkFromImageId:(NSData *)imageId inSession:(SPSession *)aSession callback:(void (^)(NSURL *url))block;
{
    NSParameterAssert(imageId != nil);
    NSParameterAssert(aSession != nil);
    NSParameterAssert(block != nil);
    
    // This is a hack. We'll see if it works. Officially, to get the url, the image
    // has to be created. Creating the image causes it to load. That's a lot of work
    // we don't want to do.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = create_url_from_image_id(imageId);
        dispatch_async(dispatch_get_main_queue(), ^() {
            block(url);
        });
    });
}

+ (SPImage *)imageWithImageId:(const byte *)imageId inSession:(SPSession *)aSession
{
	SPAssertOnLibSpotifyThread();

    NSParameterAssert(imageId != nil);
    NSParameterAssert(aSession != nil);
	
	NSData *cacheKey = [self cacheKeyFromImageId:imageId];
	SPImage *image = [g_imageCache objectForKey:cacheKey];
	if (image) {
		return image;
    }

	image = [[SPImage alloc] initWithImageId:imageId inSession:aSession];
	[g_imageCache setObject:image forKey:cacheKey];
    
	return image;
}

+ (void)imageWithImageURL:(NSURL *)imageURL inSession:(SPSession *)aSession callback:(void (^)(SPImage *image))block
{
    NSAssert([NSThread isMainThread], @"Image created off main thread");

	NSParameterAssert(imageURL != nil);
    NSParameterAssert(aSession != nil);
    NSParameterAssert(block != nil);
    
    SPImage *cachedImage = [g_imageCache objectForKey:imageURL];
    if (cachedImage) {
        block(cachedImage);
        return;
    }

	if ([imageURL spotifyLinkType] != SP_LINKTYPE_IMAGE) {
		block(nil);
		return;
	}

	SPDispatchAsync(^{
		sp_link *link = [imageURL createSpotifyLink];
        if (link == NULL) {
            return;
        }

		sp_image *image = sp_image_create_from_link(aSession.session, link);
        sp_link_release(link);

        if (image == NULL) {
            return;
        }

        SPImage *spImage = [self imageWithImageId:sp_image_image_id(image) inSession:aSession];
        sp_image_release(image);

        if (spImage) {
            [g_imageCache setObject:spImage forKey:imageURL];
        }

		dispatch_async(dispatch_get_main_queue(), ^() {
            block(spImage);
        });
	});
}

#pragma mark -

- (id)initWithImageId:(const byte *)anId inSession:aSession
{
	SPAssertOnLibSpotifyThread();
	
    if ((self = [super init])) {
        _session = aSession;
		_imageIdData = [[NSData alloc] initWithBytes:anId length:SPImageIdLength];
    }

    return self;
}

- (sp_image *)spImage
{
	SPAssertOnLibSpotifyThread();
	return _spImage;
}

- (const byte *)imageId
{
    return _imageIdData.bytes;
}

- (void)startLoading
{
	if (_hasStartedLoading) {
        return;
    }

	_hasStartedLoading = YES;

	SPDispatchAsync(^{
		NSCAssert(!self.spImage, @"Image struct already created");
        NSCAssert(!self.callbackProxy, @"Image callback already added");

		sp_image *spImage = sp_image_create(self.session.session, self.imageId);
		if (!spImage) {
            return;
        }

        self.spImage = spImage;
        self.callbackProxy = [[SPImageCallbackProxy alloc] init];
        self.callbackProxy.image = self;

        sp_image_add_load_callback(spImage, &image_loaded, (__bridge void *)(self.callbackProxy));

        BOOL isLoaded = sp_image_is_loaded(spImage);
        NSURL *url = create_image_url(spImage);

        SPPlatformNativeImage *im = nil;
        if (isLoaded) {
            im = create_native_image(spImage);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.image = im;
            self.spotifyURL = url;
            self.loaded = isLoaded;
        });
	});
}

- (void)dealloc
{
	SPImageCallbackProxy *callbackProxy = _callbackProxy;
	_callbackProxy.image = nil;

    if (_spImage) {
        sp_image *spImage = _spImage;
        SPDispatchAsync(^() {
            sp_image_remove_load_callback(spImage, &image_loaded, (__bridge void *)callbackProxy);
            sp_image_release(spImage);
        });
    }
}

@end
