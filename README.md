# emqx_mcp_gateway

The MCP Gateway is an EMQX plugin that enables MCP clients using the MCP over MQTT protocol to interact with MCP servers using other protocols.

```
                                                               ┌────────────────┐         
                                                   ┌─MCP/HTTP──┼ MCP HTTP Server│         
                                                   │           └────────────────┘         
                                                   │                                      
                                                   │                                      
                               ┌───────────────┐   │                                      
     ┌──────────┐              │               │   │           ┌─────────────────┐        
     │MCP Client┼──MCP/MQTT────┼    Gateway    ┼───┼─MCP/STDIO─┼ MCP STDIO Server│        
     └──────────┘              │               │   │           └─────────────────┘        
                               └───────────────┘   │                                      
                                                   │                                      
                                                   │                                      
                                                   │           ┌──────────────────┐       
                                                   └─CALL/gRPC─┼ MCP Server Plugin│       
                                                               └──────────────────┘       
```

## Configure MCP server names and server name filters

### Configure the Server Name for MCP/MQTT Servers

The MCP gateway supports configuring broker suggested `server names` for MCP servers, this it to avoid server name conflicts and maintain a consistent naming convention across different MCP servers.

To configure the server names for MCP servers, prepare an `mcp_server_name.csv` file with the following content:

```csv
# condition, server_name
username = 'server-user-1', devices/vehicle/xiaopeng/EP7
mcp_meta.service_type = 'vehicle', devices/vehicle/${mcp_meta.manufacturer}/${mcp_meta.vehicle_type}
```

The file is a CSV file with two columns: `condition` and `server_name`. The `condition` column is a condition that can be evaluated by the MCP gateway, and the `server_name` column is the server name that will be sent to the MCP server (by the `MCP-SERVER-NAME` user-property in the `CONNACK` packet) when the condition is met.

The `condition` can be a simple string that matches the the `username` or `clientid` of the MCP server, or it can be a more complex expression that returns a boolean value based on the `mcp_meta` or other properties of the MCP server. See [Variform Expressions](https://docs.emqx.com/en/emqx/latest/configuration/configuration.html#variform-expressions) for more details on how to write the condition.

The `server_name` can contain variables that will be replaced with the values. For example, `${mcp_meta.vehicle_type}` will be replaced with the value of the `vehicle_type` got from the `MCP-META`.

NOTE that by configuring a server name for a MCP server, the MCP gateway will automatically set ACLs to constrain the MCP server to only access the MQTT topics that match the server name.

### Configure the Server Name Filters for MCP/MQTT Clients

Similarly, we the MCP gateway can also configure `server name filters` for MCP clients, which allows the broker to guide the MCP clients to only connect to specific MCP servers that they are allowed to access.

To configure the server name filters for MCP clients, prepare an `mcp_server_name_filter.csv` file with the following content:

```csv
# condition, server_name_filters
username = 'client-user-1', devices/vehicle/#
mcp_meta.app_type = 'vehicle', devices/vehicle/xiaopeng/+;devices/vehicle/byd/+
```

The file is a CSV file with two columns: `condition` and `server_name_filters`. The `condition` column is the same as the one used in the `mcp_server_name.csv` file, and the `server_name_filters` column is a comma-separated list of server names that the client is allowed to access (Controlled by ACLs). The `server_name_filters` will be sent to the MCP client (by the `MCP-SERVER-NAME-FILTERS` user-property in the `CONNACK` packet) when the condition is met.

NOTE that by configuring server name filters for a MCP client, the MCP gateway will automatically set ACLs to constrain the MCP client to only access the MQTT topics that match the server name filters.

## Role Based Access Control (RBAC)

The MCP Gateway supports Role Based Access Control (RBAC) to manage access to MCP servers and their tools/resources. The RBAC configuration is done by preparing a `mcp_rbac.csv` file with the following content:

```csv
# condition, server_name:role_name
username = 'client-user-1', devices/vehicle/xiaopeng/EP7:admin
mcp_meta.app_id = 'app-1', devices/vehicle/xiaopeng/EP7:user
mcp_meta.app_id = 'app-2', devices/vehicle/byd/song:user;devices/vehicle/byd/tang:admin
```

When a MCP client connects to the broker, the MCP gateway will evaluate the conditions and send the `MCP-AUTH-ROLE` user-property in the `CONNACK` packet to the MCP client.

MCP servers can send presence notifications with an `rbac` field in the metadata, which is a list of role definitions that the MCP server supports. See [Service Registration](https://mqtt.ai/docs/mcp-over-mqtt/specification/2025-03-26/basic/mqtt_transport.html#service-registration).

## Examples of MCP Server configurations

### Connect to a STDIO MCP server

Add a STDIO MCP server to the configuration file:

```hocon
stdio_servers.weather = {
  enable = true
  server_name = "system_tools/office/weather"
  command = "uv"
  args = [
    "--directory",
    "/ABSOLUTE/PATH/TO/PARENT/FOLDER/weather",
    "run",
    "weather.py"
  ]
  env = [
    {"API_KEY", "eee" }
  ]
}
```

### Connect to a HTTP MCP server

Add an HTTP MCP server to the configuration file:

```hocon
http_servers.calculator = {
  enable = true
  server_name = "system_tools/math/calculator"
  url = "https://localhost:3300"
}
```

### Setup a Embedded MCP server using EMQX plugin

Build and install the plugin according to the docs.
