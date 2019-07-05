local _M = {}

local shell_execute = require "resty.auto-ssl.utils.shell_execute"

function _M.issue_cert(auto_ssl_instance, domain)
  assert(type(domain) == "string", "domain must be a string")

  local domains = {}
  local bundle = auto_ssl_instance:get("bundles")[domain]
  if bundle ~= nil then
    for _, subdomain in pairs(bundle) do
      domains[#domains+1] = subdomain .. "."..domain
    end
  else
    domains[#domains+1] = domain
  end

  local lua_root = auto_ssl_instance.lua_root
  assert(type(lua_root) == "string", "lua_root must be a string")

  local base_dir = auto_ssl_instance:get("dir")
  assert(type(base_dir) == "string", "dir must be a string")

  local hook_port = auto_ssl_instance:get("hook_server_port")
  assert(type(hook_port) == "number", "hook_port must be a number")
  assert(hook_port <= 65535, "hook_port must be below 65536")

  local hook_secret = ngx.shared.auto_ssl_settings:get("hook_server:secret")
  assert(type(hook_secret) == "string", "hook_server:secret must be a string")

  -- Run dehydrated for this domain, using our custom hooks to handle the
  -- domain validation and the issued certificates.
  --
  -- Disable dehydrated's locking, since we perform our own domain-specific
  -- locking using the storage adapter.
  local command = {
    "env",
    "HOOK_SECRET=" .. hook_secret,
    "HOOK_SERVER_PORT=" .. hook_port,
    lua_root .. "/bin/resty-auto-ssl/dehydrated",
    "--cron",
    "--accept-terms",
    "--no-lock",
  }

  for _, domain_bundled in pairs(domains) do
    command[#command + 1] = "--domain "
    command[#command + 1] = domain_bundled
  end

  command[#command + 1] = "--challenge"
  command[#command + 1] = "http-01"
  command[#command + 1] = "--config"
  command[#command + 1] = base_dir .. "/letsencrypt/config"
  command[#command + 1] = "--hook"
  command[#command + 1] = lua_root .. "/bin/resty-auto-ssl/letsencrypt_hooks"

  local result, err = shell_execute(command)
  if result["status"] ~= 0 then
    ngx.log(ngx.ERR, "auto-ssl: dehydrated failed: ", result["command"], " status: ", result["status"], " out: ", result["output"], " err: ", err)
    return nil, "dehydrated failure"
  end

  ngx.log(ngx.DEBUG, "auto-ssl: dehydrated output: " .. result["output"])

  -- The result of running that command should result in the certs being
  -- populated in our storage (due to the deploy_cert hook triggering).
  local storage = auto_ssl_instance.storage
  local cert, get_cert_err = storage:get_cert(domain)
  if get_cert_err then
    ngx.log(ngx.ERR, "auto-ssl: error fetching certificate from storage for ", domain, ": ", get_cert_err)
  end

  -- If dehydrated succeeded, but we still don't have any certs in storage, the
  -- issue might be that dehydrated succeeded and has local certs cached, but
  -- the initial attempt to deploy them and save them into storage failed (eg,
  -- storage was temporarily unavailable). If this occurs, try to manually fire
  -- the deploy_cert hook again to populate our storage with dehydrated's local
  -- copies.
  if not cert or not cert["fullchain_pem"] or not cert["privkey_pem"] then
    ngx.log(ngx.WARN, "auto-ssl: dehydrated succeeded, but certs still missing from storage - trying to manually copy - domain: " .. domain)

    local command_deploy = {
      "env",
      "HOOK_SECRET=" .. hook_secret,
      "HOOK_SERVER_PORT=" .. hook_port,
      lua_root .. "/bin/resty-auto-ssl/letsencrypt_hooks",
      "deploy_cert",
    }

    for _, domain_bundled in pairs(domains) do
      command_deploy[#command_deploy + 1] = "--domain "
      command_deploy[#command_deploy + 1] = domain_bundled
    end

    command_deploy[#command_deploy + 1] = base_dir .. "/letsencrypt/certs/" .. domain .. "/privkey.pem"
    command_deploy[#command_deploy + 1] = base_dir .. "/letsencrypt/certs/" .. domain .. "/cert.pem"
    command_deploy[#command_deploy + 1] = base_dir .. "/letsencrypt/certs/" .. domain .. "/fullchain.pem"
    command_deploy[#command_deploy + 1] = base_dir .. "/letsencrypt/certs/" .. domain .. "/chain.pem"
    command_deploy[#command_deploy + 1] = math.floor(ngx.now())
    result, err = shell_execute(command_deploy)
    if result["status"] ~= 0 then
      ngx.log(ngx.ERR, "auto-ssl: dehydrated manual hook.sh failed: ", result["command"], " status: ", result["status"], " out: ", result["output"], " err: ", err)
      return nil, "dehydrated failure"
    end

    -- Try fetching again.
    cert, get_cert_err = storage:get_cert(domain)
    if get_cert_err then
      ngx.log(ngx.ERR, "auto-ssl: error fetching certificate from storage for ", domain, ": ", get_cert_err)
    end
  end

  -- Return error if things are still unexpectedly missing.
  if not cert or not cert["fullchain_pem"] or not cert["privkey_pem"] then
    return nil, "dehydrated succeeded, but no certs present"
  end

  return cert
end

return _M
