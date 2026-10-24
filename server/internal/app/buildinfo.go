package app

// buildCommit is injected by the production Docker build. Local builds may
// report unknown when they are not produced from the deployment checkout.
var buildCommit = "unknown"
