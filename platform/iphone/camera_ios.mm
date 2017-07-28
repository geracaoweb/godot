/*************************************************************************/
/*  camera_ios.mm                                                        */
/*************************************************************************/
/*                       This file is part of:                           */
/*                           GODOT ENGINE                                */
/*                    http://www.godotengine.org                         */
/*************************************************************************/
/* Copyright (c) 2007-2017 Juan Linietsky, Ariel Manzur.                 */
/* Copyright (c) 2014-2017 Godot Engine contributors (cf. AUTHORS.md)    */
/*                                                                       */
/* Permission is hereby granted, free of charge, to any person obtaining */
/* a copy of this software and associated documentation files (the       */
/* "Software"), to deal in the Software without restriction, including   */
/* without limitation the rights to use, copy, modify, merge, publish,   */
/* distribute, sublicense, and/or sell copies of the Software, and to    */
/* permit persons to whom the Software is furnished to do so, subject to */
/* the following conditions:                                             */
/*                                                                       */
/* The above copyright notice and this permission notice shall be        */
/* included in all copies or substantial portions of the Software.       */
/*                                                                       */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF    */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.*/
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY  */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,  */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/*************************************************************************/

///@TODO this is a near duplicate of CameraOSX, we should find a way to combine those to minimise code duplication!!!!
// If you fix something here, make sure you fix it there as wel!

#include "camera_ios.h"
#include "servers/camera/camera_feed.h"
#import <AVFoundation/AVFoundation.h>

//////////////////////////////////////////////////////////////////////////
// MyCaptureSession - This is a little helper class so we can capture our frames

@interface MyCaptureSession : AVCaptureSession <AVCaptureVideoDataOutputSampleBufferDelegate> {
	Ref<CameraFeed> feed;
	size_t width[2];
	size_t height[2];
	PoolVector<uint8_t> img_data[2];

	AVCaptureDeviceInput *input;
	AVCaptureVideoDataOutput *output;
}

@end

@implementation MyCaptureSession

- (id)initForFeed:(Ref<CameraFeed>)p_feed andDevice:(AVCaptureDevice *)p_device {
	if (self = [super init]) {
		NSError *error;
		feed = p_feed;
		width[0] = 0;
		height[0] = 0;
		width[1] = 0;
		height[1] = 0;

		[self beginConfiguration];

		self.sessionPreset = AVCaptureSessionPreset1280x720;

		input = [AVCaptureDeviceInput deviceInputWithDevice:p_device error:&error];
		if (!input) {
			print_line("Couldn't get input device for camera");
		} else {
			[self addInput:input];
		}

		output = [AVCaptureVideoDataOutput new];
		if (!output) {
			print_line("Couldn't get output device for camera");
		} else {
			NSDictionary *settings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
			output.videoSettings = settings;

			// discard if the data output queue is blocked (as we process the still image)
			[output setAlwaysDiscardsLateVideoFrames:YES];

			// now set ourselves as the delegate to receive new frames. Note that we're doing this on the main thread at the moment, we may need to change this..
			[output setSampleBufferDelegate:self queue:dispatch_get_main_queue()];

			[self addOutput:output];
		}

		[self commitConfiguration];

		// kick off our session..
		[self startRunning];
	};
	return self;
}

- (void)dealloc {
	// stop running
	[self stopRunning];

	if (output) {
		[self removeOutput:output];
		[output release];
		output = nil;
	}

	if (input) {
		[self removeInput:input];
		[input release];
		input = nil;
	}

	[super dealloc];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	// This gets called every time our camera has a new image for us to process. We need to give this to our camera server
	// That in turn locks our texture which may adversely effect our performance. Apple uses a texture cache here but I'm not sure if we can use that with Godot
	// Otherwise this needs to be enhanced by implementing something similar ourselves, load the camera image into a new texture and then give the new texture
	// to Godot.

	if (feed->is_waiting()) {
		// For now, version 1, we're just doing the bare minimum to make this work...
		CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
		// int width = CVPixelBufferGetWidth(pixelBuffer);
		// int height = CVPixelBufferGetHeight(pixelBuffer);

		// It says that we need to lock this on the documentation pages but it's not in the samples
		// need to lock our base address so we can access our pixel buffers, better safe then sorry?
		CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

		// get our buffers
		unsigned char *dataY = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
		unsigned char *dataCbCr = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
		if (dataY == NULL) {
			print_line("Couldn't access Y pixel buffer data");
		} else if (dataCbCr == NULL) {
			print_line("Couldn't access CbCr pixel buffer data");
		} else {
			Ref<Image> img[2];

			{
				// do Y
				int new_width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
				int new_height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

				if ((width[0] != new_width) || (height[0] != new_height)) {
					width[0] = new_width;
					height[0] = new_height;
					img_data[0].resize(new_width * new_height);
				}

				PoolVector<uint8_t>::Write w = img_data[0].write();
				memcpy(w.ptr(), dataY, new_width * new_width);

				img[0].instance();
				img[0]->create(new_width, new_height, 0, Image::FORMAT_R8, img_data[0]);
			}

			{
				// do CbCr
				int new_width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
				int new_height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

				if ((width[1] != new_width) || (height[1] != new_height)) {
					width[1] = new_width;
					height[1] = new_height;
					img_data[1].resize(2 * new_width * new_height);
				}

				PoolVector<uint8_t>::Write w = img_data[1].write();
				memcpy(w.ptr(), dataCbCr, 2 * new_width * new_width);

				img[1].instance();
				img[1]->create(new_width, new_height, 0, Image::FORMAT_RG8, img_data[1]);
			}

			// set our texture...
			feed->set_YCbCr_imgs(img[0], img[1]);
		}

		// and unlock
		CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
	}
}

@end

//////////////////////////////////////////////////////////////////////////
// CameraFeedIOS - Subclass for camera feeds in iOS

class CameraFeedIOS : public CameraFeed {
private:
	bool is_arkit;
	AVCaptureDevice *device;
	MyCaptureSession *capture_session;

public:
	bool get_is_arkit() const;
	AVCaptureDevice *get_device() const;

	CameraFeedIOS();
	~CameraFeedIOS();

	void set_device(AVCaptureDevice *p_device);

	bool activate_feed();
	void deactivate_feed();
};

bool CameraFeedIOS::get_is_arkit() const {
	return is_arkit;
};

AVCaptureDevice *CameraFeedIOS::get_device() const {
	return device;
};

CameraFeedIOS::CameraFeedIOS() {
	capture_session = NULL;
	device = NULL;
};

void CameraFeedIOS::set_device(AVCaptureDevice *p_device) {
	device = p_device;
	if (device == NULL) {
		is_arkit = true;
		name = "ARKit";
		position = CameraFeed::FEED_BACK;
	} else {
		is_arkit = false;
		[device retain];

		// get some info
		NSString *device_name = p_device.localizedName;
		name = device_name.UTF8String;
		position = CameraFeed::FEED_UNSPECIFIED;
		if ([p_device position] == AVCaptureDevicePositionBack) {
			position = CameraFeed::FEED_BACK;
		} else if ([p_device position] == AVCaptureDevicePositionFront) {
			position = CameraFeed::FEED_FRONT;
		};
	};
};

CameraFeedIOS::~CameraFeedIOS() {
	if (capture_session != NULL) {
		[capture_session release];
		capture_session = NULL;
	};

	if (device != NULL) {
		[device release];
		device = NULL;
	};
};

bool CameraFeedIOS::activate_feed() {
	if (is_arkit) {
		// this is ignored for ARKit
	} else {
		if (capture_session) {
			// already recording!
		} else {
			// start camera capture
			capture_session = [[MyCaptureSession alloc] initForFeed:this andDevice:device];
		};
	};

	return true;
};

void CameraFeedIOS::deactivate_feed() {
	// end camera capture if we have one
	if (capture_session) {
		[capture_session release];
		capture_session = NULL;
	};
};

//////////////////////////////////////////////////////////////////////////
// MyDeviceNotifications - This is a little helper class gets notifications
// when devices are connected/disconnected

@interface MyDeviceNotifications : NSObject {
	CameraIOS *camera_server;
}

@end

@implementation MyDeviceNotifications

- (void)devices_changed:(NSNotification *)notification {
	camera_server->update_feeds();
}

- (id)initForServer:(CameraIOS *)p_server {
	if (self = [super init]) {
		camera_server = p_server;

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(devices_changed:) name:AVCaptureDeviceWasConnectedNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(devices_changed:) name:AVCaptureDeviceWasDisconnectedNotification object:nil];
	};
	return self;
}

- (void)dealloc {
	// remove notifications
	[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceWasConnectedNotification object:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceWasDisconnectedNotification object:nil];

	[super dealloc];
}

@end

MyDeviceNotifications *device_notifications = nil;

//////////////////////////////////////////////////////////////////////////
// CameraIOS - Subclass for our camera server on iPhone

void CameraIOS::update_feeds() {
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];

	// remove devices that are gone..
	for (int i = feeds.size() - 1; i >= 0; i--) {
		Ref<CameraFeedIOS> feed = (Ref<CameraFeedIOS>)feeds[i];

		if (feed->get_is_arkit()) {
			// ignore, this is our arkit entry
		} else if (![devices containsObject:feed->get_device()]) {
			// remove it from our array, this will also destroy it ;)
			remove_feed(feed);
		};
	};

	// add new devices..
	for (AVCaptureDevice *device in devices) {
		bool found = false;
		for (int i = 0; i < feeds.size() && !found; i++) {
			Ref<CameraFeedIOS> feed = (Ref<CameraFeedIOS>)feeds[i];
			if (feed->get_device() == device) {
				found = true;
			};
		};

		if (!found) {
			Ref<CameraFeedIOS> newfeed;
			newfeed.instance();
			newfeed->set_device(device);
			add_feed(newfeed);
		};
	};
};

CameraIOS::CameraIOS() {

	// Make sure our first camera feed is our ARKit camera.
	// When ARKit is active this is what we're streaming too.
	// Note that this camera is mostly a place holder and most of the action is governed by ARKitInterface
	CameraFeedIOS * new_arkit_feed = new CameraFeedIOS();
	new_arkit_feed->set_device(NULL);

	arkit_feed = new_arkit_feed;
	add_feed(arkit_feed);

	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
							 completionHandler:^(BOOL granted) {
								 if (granted) {
									 // Find available cameras we have at this time
									 update_feeds();

									 // should only have one of these....
									 device_notifications = [[MyDeviceNotifications alloc] initForServer:this];
								 } else {
									 print_line("No access to cameras!");
								 }
							 }];
};

CameraIOS::~CameraIOS() {
	[device_notifications release];
};

CameraFeed *CameraIOS::get_arkit_feed() {
	CameraIOS *camera_server = (CameraIOS *)CameraServer::get_singleton();
	if (camera_server == NULL) {
		return NULL;
	} else {
		return camera_server->arkit_feed;
	}
};
