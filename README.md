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

## Usage Examples

### Configure the Server Name for MCP/MQTT Servers

The MCP gateway supports configuring broker suggested `server names` for MCP servers, this it to avoid server name conflicts and maintain a consistent naming convention across different MCP servers.

To configure the server names for MCP servers, prepare an `mcp_server_name.csv` file with the following content:

```csv
# condition, server_name
username = 'user-1', devices/vehicle/vin001
user_props.service_type = 'vehicle', devices/vehicle/${user_props.vsn}/${user_props.vin}
```

The file is a CSV file with two columns: `condition` and `server_name`. The `condition` column is a condition that can be evaluated by the MCP gateway, and the `server_name` column is the server name that will be sent to the MCP server (by the `MCP-SERVER-NAME` user-property in the `CONNACK` packet) when the condition is met.

The `condition` can be a simple string that matches the the `username` or `clientid` of the MCP server, or it can be a more complex expression that returns a boolean value based on the `user_props` or other properties of the MCP server.

The `server_name` can contain variables that will be replaced with the values. For example, `${user_props.vin}` will be replaced with the value of the `vin` property of the MCP server.

### Configure the Server Name Filters for MCP/MQTT Clients

Similarly, we the MCP gateway can also configure `server name filters` for MCP clients, which allows clients to filter the MCP servers based on their permissions (ACLs) or other conditions.

To configure the server name filters for MCP clients, prepare an `mcp_server_name_filter.csv` file with the following content:

```csv
# condition, server_name_filters
username = 'user-1', devices/vehicle/vin001
user_props.app_type = 'vehicle', devices/vehicle/v1/+;devices/vehicle/v2/+
```

The file is a CSV file with two columns: `condition` and `server_name_filters`. The `condition` column is the same as the one used in the `mcp_server_name.csv` file, and the `server_name_filters` column is a comma-separated list of server names that the client is allowed to access (Controlled by ACLs). The `server_name_filters` will be sent to the MCP client (by the `MCP-SERVER-NAME-FILTERS` user-property in the `CONNACK` packet) when the condition is met.

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
