#!/bin/bash
gdbus call --system \
  --dest org.freedesktop.PolicyKit1 \
  --object-path /org/freedesktop/PolicyKit1/Authority \
  org.freedesktop.PolicyKit1.Authority.CheckAuthorization \
  "(s(s{sv})a{ss}usb)" \
  "org.manjaro.pamac.commit" {} {} true ""
