/*************************************************************************/
/*  camera_feed.cpp                                                      */
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

#include "camera_feed.h"
#include "servers/visual_server.h"

void CameraFeed::_bind_methods() {
	ClassDB::bind_method(D_METHOD("id"), &CameraFeed::get_id);
	ClassDB::bind_method(D_METHOD("get_name"), &CameraFeed::get_name);
	ClassDB::bind_method(D_METHOD("set_name", "name"), &CameraFeed::set_name);

	ClassDB::bind_method(D_METHOD("get_is_active"), &CameraFeed::get_is_active);
	ClassDB::bind_method(D_METHOD("set_is_active", "active"), &CameraFeed::set_is_active);

	ClassDB::bind_method(D_METHOD("get_position"), &CameraFeed::get_position);
	ClassDB::bind_method(D_METHOD("set_position", "position"), &CameraFeed::set_position);

	ClassDB::bind_method(D_METHOD("set_RGB_img", "img"), &CameraFeed::set_RGB_img);
	ClassDB::bind_method(D_METHOD("set_YCbCr_imgs", "y_img", "cbcr_img"), &CameraFeed::set_YCbCr_imgs);

	BIND_ENUM_CONSTANT(FEED_UNSPECIFIED);
	BIND_ENUM_CONSTANT(FEED_FRONT);
	BIND_ENUM_CONSTANT(FEED_BACK);
};

int CameraFeed::get_id() const {
	return id;
};

bool CameraFeed::get_is_active() const {
	return active;
};

void CameraFeed::set_is_active(bool p_is_active) {
	if (p_is_active == active) {
		// all good
	} else if (p_is_active) {
		// attempt to activate this feed
		if (activate_feed()) {
			print_line("Activate " + name);
			active = true;
		}
	} else {
		// just deactivate it
		deactivate_feed();
		print_line("Deactivate " + name);
		active = false;
	};
};

String CameraFeed::get_name() const {
	return name;
};

void CameraFeed::set_name(String p_name) {
	name = p_name;
};

CameraFeed::FeedDataType CameraFeed::get_datatype() const {
	return datatype;
};

CameraFeed::FeedPosition CameraFeed::get_position() const {
	return position;
};

void CameraFeed::set_position(CameraFeed::FeedPosition p_position) {
	position = p_position;
};

RID CameraFeed::get_texture(int p_which) {
	int set = 0;

	if (state == FEED_WAITING_ON_0) {
		// still waiting on set 0 to be updated, so return 1
		set = 1;
	} else if (state == FEED_UPDATING_0) {
		// set 0 is still being updated, so return 1
		set = 1;
	} else if (state == FEED_0_IS_AVAILABLE) {
		// set 0 is available, we'll start using it and tell our camera to update set 1
		set = 0;
		if ((datatype == FEED_RGB) || (p_which == 1)) {
			state = FEED_WAITING_ON_1;
		}
	} else if (state == FEED_WAITING_ON_1) {
		// still waiting on set 1 to be updated, so return 0
		set = 0;
	} else if (state == FEED_UPDATING_1) {
		// set 1 is still being updated, so return 0
		set = 0;
	} else if (state == FEED_1_IS_AVAILABLE) {
		// set 1 is available, we'll start using it and tell our camera to update set 1
		set = 1;
		if ((datatype == FEED_RGB) || (p_which == 1)) {
			state = FEED_WAITING_ON_0;
		}
	};

	return texture[set][p_which];
};

CameraFeed::CameraFeed() {
	// initialize our feed
	id = CameraServer::get_singleton()->get_free_id();
	name = "???";
	active = false;
	datatype = CameraFeed::FEED_RGB;
	position = CameraFeed::FEED_UNSPECIFIED;

	// create a texture object
	///@TODO rewrite this so we only need one texture but can support two planes, or that we always convert to RGB
	VisualServer *vs = VisualServer::get_singleton();
	texture[0][0] = vs->texture_create();
	texture[0][1] = vs->texture_create();
	texture[1][0] = vs->texture_create();
	texture[1][1] = vs->texture_create();

	state = FEED_WAITING_ON_0;
};

CameraFeed::CameraFeed(String p_name, FeedPosition p_position) {
	// initialize our feed
	id = CameraServer::get_singleton()->get_free_id();
	base_width = 0;
	base_height = 0;
	name = p_name;
	active = false;
	datatype = CameraFeed::FEED_NOIMAGE;
	position = p_position;

	// create a texture object
	///@TODO rewrite this so we only need one texture but can support two planes, or that we always convert to RGB
	VisualServer *vs = VisualServer::get_singleton();
	texture[0][0] = vs->texture_create();
	texture[0][1] = vs->texture_create();
	texture[1][0] = vs->texture_create();
	texture[1][1] = vs->texture_create();
	state = FEED_WAITING_ON_0;
};

CameraFeed::~CameraFeed() {
	// Free our textures
	VisualServer *vs = VisualServer::get_singleton();
	vs->free(texture[0][0]);
	vs->free(texture[0][1]);
	vs->free(texture[1][0]);
	vs->free(texture[1][1]);
};

int CameraFeed::write_to_set() {
	if (!active) {
		return -1;
	} else if (state == FEED_WAITING_ON_0) {
		state = FEED_UPDATING_0;
		return 0;
	} else if (state == FEED_WAITING_ON_1) {
		state = FEED_UPDATING_1;
		return 1;
	} else {
		return -1;
	};
};

bool CameraFeed::is_waiting() {
	if (!active) {
		return false;
	} else if (state == FEED_WAITING_ON_0) {
		return true;
	} else if (state == FEED_WAITING_ON_1) {
		return true;
	} else {
		return false;
	};
};

void CameraFeed::set_RGB_img(Ref<Image> p_img) {
	int set = write_to_set();
	if (set >= 0) {
		VisualServer *vs = VisualServer::get_singleton();

		int new_width = p_img->get_width();
		int new_height = p_img->get_height();

		if ((base_width != new_width) || (base_height != new_height)) {
			// We're assuming here that our camera image doesn't change around formats etc, allocate the whole lot...
			base_width = new_width;
			base_height = new_height;

			vs->texture_allocate(texture[0][0], new_width, new_height, 0, Image::FORMAT_RGB8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAGS_DEFAULT);
			vs->texture_allocate(texture[1][0], new_width, new_height, 0, Image::FORMAT_RGB8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAGS_DEFAULT);
		};

		vs->texture_set_data(texture[set][0], p_img);
		datatype = CameraFeed::FEED_RGB;

		state = set == 0 ? FEED_0_IS_AVAILABLE : FEED_1_IS_AVAILABLE;
	};
};

void CameraFeed::set_YCbCr_imgs(Ref<Image> p_y_img, Ref<Image> p_cbcr_img) {
	int set = write_to_set();
	if (set >= 0) {
		VisualServer *vs = VisualServer::get_singleton();

		///@TODO investigate whether we can use thirdparty/misc/yuv2rgb.h here to convert our YUV data to RGB, our shader approach is potentially faster though..
		// Wondering about including that into multiple projects, may cause issues.
		// That said, if we convert to RGB, we could enable using texture resources again...

		int new_y_width = p_y_img->get_width();
		int new_y_height = p_y_img->get_height();
		int new_cbcr_width = p_cbcr_img->get_width();
		int new_cbcr_height = p_cbcr_img->get_height();

		if ((base_width != new_y_width) || (base_height != new_y_height)) {
			// We're assuming here that our camera image doesn't change around formats etc, allocate the whole lot...
			base_width = new_y_width;
			base_height = new_y_height;

			vs->texture_allocate(texture[0][0], new_y_width, new_y_height, 0, Image::FORMAT_R8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAG_USED_FOR_STREAMING);
			vs->texture_allocate(texture[1][0], new_y_width, new_y_height, 0, Image::FORMAT_R8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAG_USED_FOR_STREAMING);

			vs->texture_allocate(texture[0][1], new_cbcr_width, new_cbcr_height, 0, Image::FORMAT_RG8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAG_USED_FOR_STREAMING);
			vs->texture_allocate(texture[1][1], new_cbcr_width, new_cbcr_height, 0, Image::FORMAT_RG8, VS::TEXTURE_TYPE_2D, VS::TEXTURE_FLAG_USED_FOR_STREAMING);
		};

		vs->texture_set_data(texture[set][0], p_y_img);
		vs->texture_set_data(texture[set][1], p_cbcr_img);
		datatype = CameraFeed::FEED_YCbCr;

		state = set == 0 ? FEED_0_IS_AVAILABLE : FEED_1_IS_AVAILABLE;
	};
};

bool CameraFeed::activate_feed() {
	// nothing to do here
	return true;
};

void CameraFeed::deactivate_feed(){
	// nothing to do here
};
