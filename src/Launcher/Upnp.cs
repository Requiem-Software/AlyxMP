using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace AlyxMP
{
    /// <summary>
    /// Opens the host's port on the router through Windows' built-in UPnP NAT COM object, so friends can
    /// connect without manual port forwarding. Only used when the host ticks the box.
    /// </summary>
    static class Upnp
    {
        const string Description = "Alyx MP";

        /// <summary>Maps the TCP port and returns the router's external IP, or null with a reason.</summary>
        public static string Open(int port, out string error)
        {
            error = null;
            try
            {
                var maps = Collection();
                if (maps == null)
                {
                    error = "your router didn't answer (UPnP may be off)";
                    return null;
                }
                try { maps.Remove(port, "TCP"); } catch (Exception) { }
                var mapping = maps.Add(port, "TCP", port, LocalIp(), true, Description);
                string ip = mapping?.ExternalIPAddress;
                return string.IsNullOrEmpty(ip) ? "?" : ip;
            }
            catch (Exception e)
            {
                error = e.Message;
                return null;
            }
        }

        public static void Close(int port)
        {
            try { Collection()?.Remove(port, "TCP"); } catch (Exception) { }
        }

        static dynamic Collection()
        {
            var type = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
            if (type == null) return null;
            dynamic nat = Activator.CreateInstance(type);
            return nat.StaticPortMappingCollection;
        }

        /// <summary>The LAN address of the interface with a default gateway (the one facing the router).</summary>
        public static string LocalIp()
        {
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    var props = ni.GetIPProperties();
                    if (!props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any))) continue;
                    var ip = props.UnicastAddresses.FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
                    if (ip != null) return ip.Address.ToString();
                }
            }
            catch (Exception) { }
            return "127.0.0.1";
        }
    }
}
