const guidScope = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([A-Za-z0-9][A-Za-z0-9_.-]*)$/i;

export function isSelfGuidScope(scope, clientId) {
  const match = typeof scope === 'string' && guidScope.exec(scope);
  return !!match && match[1].toLowerCase() === clientId?.toLowerCase();
}

export function tokenScope(config) {
  const prefix = `api://${config.clientId}/`;
  // AADSTS90009: self-resource tokens require the GUID resource, not its identifier URI.
  return config.scope.toLowerCase().startsWith(prefix.toLowerCase())
    ? `${config.clientId}/${config.scope.slice(prefix.length)}` : config.scope;
}

export function matchesTokenScope(scope, config) {
  if (typeof scope !== 'string') return false;
  const requested = tokenScope(config);
  const equivalent = isSelfGuidScope(requested, config.clientId) ? `api://${requested}` : requested;
  return [requested, equivalent].some((expected) => scope.toLowerCase() === expected.toLowerCase());
}
