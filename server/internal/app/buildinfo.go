package app

// buildCommit is injected by the production Docker build. Local builds may
// report unknown when they are not produced from the deployment checkout.
var buildCommit = "unknown"

func safeBuildCommit(value string) string {
	if value == "unknown" {
		return value
	}
	if len(value) < 7 || len(value) > 40 {
		return "unknown"
	}
	for _, char := range value {
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return "unknown"
		}
	}
	return value
}
