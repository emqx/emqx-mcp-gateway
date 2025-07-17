# EMQX MCP Gateway

The MCP Gateway is an EMQX plugin that:

1. Enables MCP clients using the MCP over MQTT protocol to interact with MCP servers using other protocols.
2. Provides a unified method for managing and assigning MCP server-names on the MQTT broker.
3. Simplifies the process of configuring ACLs for both MCP servers and clients.
4. Offers role-based access control.

Below is a diagram illustrating how an MCP over MQTT client interacts with clients using other protocols through this gateway plugin:

```
                                                               ┌────────────────┐         
                                                   ┌─MCP/HTTP──┼ MCP HTTP Server│         
                                                   │           └────────────────┘         
                                                   │                                      
                                                   │                                      
                               ┌───────────────┐   │                                      
     ┌──────────┐              │               │   │           ┌─────────────────┐        
     │MCP Client┼──MCP-MQTT────┼    Gateway    ┼───┼─MCP/STDIO─┼ MCP STDIO Server│        
     └──────────┘              │               │   │           └─────────────────┘        
                               └───────────────┘   │                                      
                                                   │                                      
                                                   │                                      
                                                   │           ┌──────────────────┐       
                                                   └─CALL/gRPC─┼ MCP Server Plugin│       
                                                               └──────────────────┘       
```

## Configure MCP server names and server name filters

### Configure the Server Name for MCP-MQTT Servers

The MCP gateway supports configuring broker suggested `server names` for MCP servers, this it to avoid server name conflicts and maintain a consistent naming convention across different MCP servers.

To configure the server names for MCP servers, prepare an `mcp_server_name.json` file with the following content:

```json
[
  {"condition": "select * where username = 'server-user-1'", "server_name": "devices/vehicle/xiaopeng/EP7"},
  {"condition": "select * where mcp_meta.service_type = 'vehicle'", "server_name": "devices/vehicle/{{mcp_meta.manufacturer}}/{{mcp_meta.vehicle_type}}"}
]
```

The file is a JSON file with a list of objects. Each object has two field: `condition` and `server_name`.
The `condition` is a condition that can be evaluated by the MCP gateway, and the `server_name` is the server name that will be sent to the MCP server (by the `MCP-SERVER-NAME` user-property in the `CONNACK` packet) when the condition is met.

The `condition` can be a SQL expression that matches the the `username`, `clientid`, `mcp_meta` or other MQTT properties of the MCP server.

The `server_name` is a template string that will be rendered as the server suggested server_name. For example, `{{mcp_meta.vehicle_type}}` will be replaced with the value of the `vehicle_type` got from the `MCP-META`.

NOTE that by configuring a server name, the MCP gateway will automatically set ACLs to constrain the MCP server to only access the MQTT topics that match the server name.

### Configure the Server Name Filters for MCP-MQTT Clients

Similarly, the MCP gateway can also configure `server name filters` for MCP clients, which allows the broker to guide the MCP clients to only connect to specific MCP servers that they are allowed to access.

To configure the server name filters for MCP clients, prepare an `mcp_server_name_filter.json` file with the following content:

```json
[
  {"condition": "select * where username = 'user-1'", "server_name_filters": ["devices/vehicle/#"]},
  {"condition": "select * where mcp_meta.app_type = 'vehicle'", "server_name_filters": ["devices/vehicle/xiaopeng/+", "devices/vehicle/byd/+"]}
]
```

The file contains a list of JSON objects with two fields: `condition` and `server_name_filters`. The `condition` is the same as the one used in the `mcp_server_name.json` file, and the `server_name_filters` is a list of server name filters that the client is allowed to access (Controlled by ACLs). The `server_name_filters` will be sent to the MCP client (by the `MCP-SERVER-NAME-FILTERS` user-property in the `CONNACK` packet) when the condition is met.

NOTE that by configuring server name filters for a MCP client, the MCP gateway will automatically set ACLs to constrain the MCP client to only access the MQTT topics that match the server name filters.

## Role Based Access Control (RBAC)

The MCP Gateway supports Role Based Access Control (RBAC) to manage access to MCP servers and their tools/resources. The RBAC configuration is done by preparing a `mcp_rbac.json` file with the following content:

```json
[
  {
    "condition": "select * where username = 'user-1'",
    "rbac": [
      {"server_name": "devices/vehicle/xiaopeng/EP7", "role": "admin"}
    ]
  },
  {
    "condition": "select * where mcp_meta.app_id = 'app-1'",
    "rbac": [
      {"server_name": "devices/vehicle/byd/song", "role": "admin"},
      {"server_name": "devices/vehicle/byd/tang", "role": "user"}
    ]
  }
]
```

When a MCP client connects to the broker, the MCP gateway will evaluate the conditions and send the `MCP-RBAC` user-property in the `CONNACK` packet to the MCP client.

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
