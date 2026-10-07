/*
 * Generated with AI assistance (Claude Sonnet 5, model id: claude-sonnet-5).
 * Copied from app/starter/cloud_config.h as the starting point for FEVengersApp.
 */

/*
 * Copyright (c) Microsoft
 * Copyright (c) 2024 Eclipse Foundation
 *
 *  This program and the accompanying materials are made available
 *  under the terms of the MIT license which is available at
 *  https://opensource.org/license/mit.
 *
 *  SPDX-License-Identifier: MIT
 *
 *  Contributors:
 *     Microsoft         - Initial version
 *     Frédéric Desbiens - 2024 version.
 */

#ifndef _CLOUD_CONFIG_H
#define _CLOUD_CONFIG_H

#include "nx_api.h"

typedef enum
{
    None         = 0,
    WEP          = 1,
    WPA_PSK_TKIP = 2,
    WPA2_PSK_AES = 3
} WiFi_Mode;

// ----------------------------------------------------------------------------
// WiFi connection config
// ----------------------------------------------------------------------------
// Fill in WIFI_SSID and WIFI_PASSWORD before building (2.4 GHz network only).
// They are empty in the repository on purpose: do not commit them.
#define HOSTNAME      "MxChip-FEV"  //Change to unique hostname.
#define WIFI_SSID     ""
#define WIFI_PASSWORD ""
#define WIFI_MODE     WPA2_PSK_AES

// ----------------------------------------------------------------------------
// MQTT Config
// ----------------------------------------------------------------------------
#define MQTT_CLIENT_NAME       "FEVengersThreadX"  //Change to unique name.
// Address of the machine that runs AutoSD (QEMU forwards its port 1883 to
// the broker inside). "./autosd/autosd.sh status" prints the address to put
// here; it must be on the same subnet as the board's Wi-Fi.
#define MQTT_LOCAL_BROKER_IP   (IP_ADDRESS(192, 168, 88, 248))
#define MQTT_BROKER_PORT       1883
// Single topic for everything now - no separate heartbeat topic. Payload:
// {"temperature_degC": <float>, "counter": <0-255 rolling counter>}.
#define MQTT_TELEMETRY_TOPIC   "FEVengers_MQTT/telemetry"

// Set to 0 to make mqtt_thread_entry skip nxd_mqtt_client_create/_connect
// entirely (sensor reading, fault modes, the RGB LED, and the OLED are
// unaffected either way - only actual MQTT publishing is gated by this).
// Was temporarily 0 while MQTT_LOCAL_BROKER_IP was still a placeholder, to
// rule it out as the cause of a reported hang - the hang still reproduced
// with this at 0, so the placeholder/unreachable-broker connect was NOT
// the (sole) cause. Re-enabled now that a real broker address is set.
#define MQTT_BROKER_CONFIGURED 1

#endif // _CLOUD_CONFIG_H
