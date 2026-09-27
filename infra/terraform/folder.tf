resource "openobserve_folder" "reliability" {
  name        = "Reliability"
  description = "Production reliability alerts — Dataset v3 incidents 001-009, 012"
  folder_type = "alerts"
}

resource "openobserve_folder" "safety" {
  name        = "Safety"
  description = "Safety and dedup scenarios — Dataset v3 incidents 010, 011"
  folder_type = "alerts"
}
