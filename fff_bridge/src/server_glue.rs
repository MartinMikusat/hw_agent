
// ---- hw_agent glue (appended to fff-mcp's server.rs by build.rs) ----

/// Runs one fff-mcp tool with JSON arguments. Ok carries the tool's text and
/// whether the tool flagged it as an error.
pub(crate) fn hw_call(server: &FffServer, name: &str, args: &str) -> Result<(String, bool), String> {
    fn parse<T: serde::de::DeserializeOwned>(args: &str) -> Result<T, String> {
        serde_json::from_str(args).map_err(|e| format!("invalid arguments: {e}"))
    }
    let result = match name {
        "find_files" => server.find_files(Parameters(parse(args)?)),
        "grep" => server.grep(Parameters(parse(args)?)),
        "multi_grep" => server.multi_grep(Parameters(parse(args)?)),
        _ => return Err(format!("unknown fff tool {name}")),
    };
    match result {
        Ok(r) => {
            let text: Vec<String> = r.content.iter().filter_map(|c| c.as_text().map(|t| t.text.clone())).collect();
            Ok((text.join("\n"), r.is_error.unwrap_or(false)))
        }
        Err(e) => Err(e.message.to_string()),
    }
}

/// fff-mcp's tool definitions (name, description, input schema) as JSON.
pub(crate) fn hw_tools_json() -> String {
    serde_json::to_string(&FffServer::tool_router().list_all()).unwrap_or_else(|_| "[]".into())
}
