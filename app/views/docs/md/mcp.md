Dandelion supports the [Model Context Protocol](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) (MCP), so AI assistants can search and look up Dandelion events, organisations, gatherings, and accounts.

## What AI assistants can do

- Search events (recent and upcoming), organisations, gatherings and accounts
- Look up events, organisations, gatherings and accounts, by slug/username or ID
- Get trending events
- Get upcoming events for an organisation
- Get the authenticated account (requires an API key)
- Get completed orders and tickets for an event you admin (requires an API key)

All access is read-only. Email addresses are included only when you are allowed to view them.

## MCP endpoint

Add the Dandelion MCP server to your AI assistant's MCP configuration:

```
https://dandelion.events/mcp
```

## Authentication

Public tools work without authentication. Authenticated tools, such as Get Me, Get Event Orders and Get Event Tickets, require your API key as a Bearer token.

You can find your API key on your [profile edit page](/accounts/edit).

```json
{
  "mcpServers": {
    "dandelion": {
      "url": "https://dandelion.events/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```
