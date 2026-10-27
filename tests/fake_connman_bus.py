#!/usr/bin/python3
"""Private D-Bus test fixture. Never connects to the host system bus."""
import json
import sys
import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection(sys.argv[1])
name = dbus.service.BusName('net.connman', bus)
initial = json.loads(sys.argv[2])
class FakeConnMan(dbus.service.Object):
    def __init__(self):
        super().__init__(bus, '/net/connman/service/ethernet_fixture')
        self.config = initial
    @dbus.service.method('net.connman.Service', in_signature='', out_signature='a{sv}')
    def GetProperties(self):
        return {
            'State': dbus.String('online'),
            'Nameservers.Configuration': dbus.Array(self.config, signature='s'),
            'Nameservers': dbus.Array(self.config or ['192.0.2.1'], signature='s'),
        }
    @dbus.service.method('net.connman.Service', in_signature='sv', out_signature='')
    def SetProperty(self, key, value):
        if key != 'Nameservers.Configuration' or not isinstance(value, dbus.Array):
            raise dbus.exceptions.DBusException('InvalidArguments')
        self.config = [str(item) for item in value]
obj = FakeConnMan()
print('READY', flush=True)
GLib.MainLoop().run()
