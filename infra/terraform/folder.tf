resource "openobserve_folder" "reliability" {
  name        = "Reliability"
  description = "Reliability alerts — AutoSRE incidents 001-009 and 012"
  folder_type = "alerts"
}

resource "openobserve_folder" "safety" {
  name        = "Safety"
  description = "Safety and deduplication canaries — AutoSRE incidents 010-011"
  folder_type = "alerts"
}
