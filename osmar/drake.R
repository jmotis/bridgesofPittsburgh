# Drake ----

pkgconfig::set_config(
  "drake::strings_in_dots" = "literals",
  "drake::verbose" = 4)

suppressPackageStartupMessages({
library(drake)
library(osmar)
library(tidyverse)
library(tidygraph)
library(igraph)
library(rgdal)
library(assertr)
library(httr)
library(parallel)
library(geosphere)
library(sf)
library(fs)
library(mapview)
library(dequer)
library(konigsbergr)
library(pathfinder)
library(jsonlite)
library(htmltools)
library(bigosm)
})

# Load all functions
dir_walk("osmar/R", source)

# Build graph ----

pgh_plan <- drake_plan(
  download_osm = get_osm_bbox(-80.1257, -79.7978, 40.3405, 40.5407),
  pgh_nodes_sf = osm_nodes_to_sf(download_osm),
  # Shapefile for PGH boundaries
  pgh_boundary_layer = read_sf(file_in("osmar/input_data/Pittsburgh_River_Boundary")),
  pgh_block_data_layer = read_sf(file_in("osmar/input_data/Neighborhoods_")),
  in_bound_points = nodes_within_boundaries(pgh_nodes_sf, pgh_boundary_layer),
  node_communities = st_join(pgh_nodes_sf, pgh_block_data_layer),
  pgh_unlimited_graph = konigsberg_graph(src = download_osm, path_filter = automobile_highways, bridge_filter = main_bridges),
  pgh_filtered_graph = filter_bridges_to_nodes(pgh_unlimited_graph, node_ids = in_bound_points),
  pgh_tidy_graph = pgh_filtered_graph %>% 
    activate(nodes) %>% 
    left_join(select(st_set_geometry(node_communities, NULL), id, neighborhood = hood) %>% distinct(id, .keep_all = TRUE), by = "id"),
  pgh_edge_bundles = collect_edge_bundles(pgh_tidy_graph),
  pgh_bridge_node_correspondence = bridge_node_correspondence(pgh_tidy_graph, pgh_edge_bundles),
  node_sibling_lookup = lapply(pgh_bridge_node_correspondence$node_index, function(x) 
    as.character(unique(pgh_bridge_node_correspondence$node_index[pgh_bridge_node_correspondence$bridge_id == pgh_bridge_node_correspondence$bridge_id[pgh_bridge_node_correspondence$node_index == x]]))) %>% 
    set_names(as.character(pgh_bridge_node_correspondence$node_index)),
  
  pgh_decorated_graph = decorate_graph(pgh_tidy_graph, pgh_edge_bundles, E(pgh_tidy_graph)$distance),
  pgh_all_distances = full_matrix(pgh_decorated_graph),
  pgh_bridgeless_distances = inter_bridge_matrix(pgh_decorated_graph, node_sibling_lookup),
  pgh_bridge_only_distances = intra_bridge_matrix(pgh_decorated_graph),
  
  pgh_all_distances_matrix = write.csv(pgh_all_distances$distance_matrix, na = "",
                                       file = file_out("osmar/output_data/distance_matrices/all/all_distance_matrix.csv")),
  pgh_all_paths_list = write_lines(toJSON(pgh_all_distances$path_list, pretty = TRUE), path = file_out("osmar/output_data/distance_matrices/all/all_pathways.json")),
  
  pgh_bridgeless_matrix = write.csv(pgh_bridgeless_distances$distance_matrix, na = "",
                                       file = file_out("osmar/output_data/distance_matrices/inter_bridge/inter_distance_matrix.csv")),
  pgh_bridgeless_list = write_lines(toJSON(pgh_bridgeless_distances$path_list, pretty = TRUE), path = file_out("osmar/output_data/distance_matrices/inter_bridge/inter_pathways.json")),
  
  pgh_bridge_only_distances_matrix = write.csv(pgh_bridge_only_distances$distance_matrix, na = "",
                                       file = file_out("osmar/output_data/distance_matrices/intra_bridge/intra_distance_matrix.csv")),
  pgh_bridge_only_paths_list = write_lines(toJSON(pgh_bridge_only_distances$path_list, pretty = TRUE), path = file_out("osmar/output_data/distance_matrices/intra_bridge/intra_pathways.json")),
  
  pgh_nodes = write_csv(write_nodelist(pgh_tidy_graph), path = file_out("osmar/output_data/pgh_nodes.csv"), na = ""),
  pgh_edges = write_csv(write_edgelist(pgh_tidy_graph), path = file_out("osmar/output_data/pgh_edges.csv"), na = ""),
  
  flat_graph = as.undirected(pgh_decorated_graph, mode = "collapse", edge.attr.comb = list(id = "first", pathfinder.distance = "first", "ignore")) %>% 
    as_tbl_graph() %>% 
    activate(edges) %>% 
    left_join(select(write_edgelist(pgh_tidy_graph), -from, -to, -distance), by = "id"),
  simplified_graph = simplify_topology(flat_graph, protected_nodes = which(vertex_attr(flat_graph, "pathfinder.interface")), edge_attr_comb = list(pathfinder.distance = sum, .default.combiner = first)),
  simplified_pgh_nodes = as_tbl_graph(simplified_graph) %>% 
    write_nodelist() %>% 
    write_csv(path = file_out("osmar/output_data/simplified/simplified_pgh_nodes.csv"), na = ""),
  simplified_pgh_edges = as_tbl_graph(simplified_graph) %>% 
    activate(edges) %>% 
    rename(label = osm_label, distance = pathfinder.distance) %>% 
    write_edgelist() %>% 
    write_csv(path = file_out("osmar/output_data/simplified/simplified_pgh_edges.csv"), na = ""),

  pgh_node_corr_tbl = write_csv(pgh_bridge_node_correspondence, na = "",
                                         path = file_out("osmar/output_data/distance_matrices/bridge_node_correspondence.csv")),

  full_pathway = greedy_search(pgh_tidy_graph, edge_bundles = pgh_edge_bundles, 
                           distances = E(pgh_tidy_graph)$distance, starting_point = V(pgh_tidy_graph)[id == 5312910192]),
  path_result = write_lines(toJSON(full_pathway$epath, pretty = TRUE), path = file_out("osmar/output_data/completed_paths/edge_steps.json")),
  path_summary = write_csv(glance(full_pathway), na = "", path = file_out("osmar/output_data/completed_paths/path_summary.csv")),
  path_details = write_csv(augment_edges(full_pathway), na = "", path = file_out("osmar/output_data/completed_paths/path_details.csv")),
  path_as_text = bridge_text_table(pgh_tidy_graph, full_pathway),
  bridges_only_path_text = filter(path_as_text, is_bridge == TRUE),
  write_lines(bridge_text_html(path_as_text), path = file_out("osmar/output_data/completed_paths/path_ordered_list.html")),
  write_lines(bridge_text_html(bridges_only_path_text), path = file_out("osmar/output_data/completed_paths/path_ordered_list_bridges_only.html")),
  
  # River bridges only
  river_bridges = read_csv(file_in("osmar/input_data/river_bridges.csv"), col_types = "n")[["bridge_id"]],
  river_pathway = cross_specific_bridges(pgh_tidy_graph, required_bridges = river_bridges, starting_node = 5312910192),
  river_pathway_sf = produce_pathway_sf(graph = pgh_tidy_graph, pathway = river_pathway),
  river_bridge_centroid_sf = bridge_centroids(graph = pgh_tidy_graph, pathway = river_pathway),
  river_pathway_sf_rda = save(river_pathway_sf, file = file_out("osmar/output_data/completed_paths/river_pathway_sf.rda")),
  river_bridge_centroid_sf_rda = save(river_bridge_centroid_sf, file = file_out("osmar/output_data/completed_paths/river_bridge_centroid_sf.rda")),
  
  # Pedestrian path
  pedestrian_graph = konigsberg_graph(download_osm, path_filter = pedestrian_highways, bridge_filter = main_bridges),
  pedestrian_pathway = cross_all_bridges(pedestrian_graph),
  pedestrian_map = view_konigsberg_path(pedestrian_graph, pedestrian_pathway),
  pedestrian_pathway_sf = produce_pathway_sf(graph = pedestrian_graph, pathway = pedestrian_pathway),
  pedestrian_bridge_centroid_sf = bridge_centroids(graph = pedestrian_graph, pathway = pedestrian_pathway),
  pedestrian_pathway_sf_rda = save(pedestrian_pathway_sf, file = file_out("osmar/output_data/completed_paths/pedestrian_pathway_sf.rda")),
  pedestrian_bridge_centroid_sf_rda = save(pedestrian_bridge_centroid_sf, file = file_out("osmar/output_data/completed_paths/pedestrian_bridge_centroid_sf.rda")),
  
  
  # For visualization purposes only keep the graph within city limits + any
  # additional edges traversed by the pathway
  pathway_sf = produce_pathway_sf(graph = pgh_tidy_graph, pathway = full_pathway),
  bridge_centroid_sf = bridge_centroids(graph = pgh_tidy_graph, pathway = full_pathway),
  pathway_sf_rda = save(pathway_sf, file = file_out("osmar/output_data/completed_paths/pathway_sf.rda")),
  bridge_centroid_sf_rda = save(bridge_centroid_sf, file = file_out("osmar/output_data/completed_paths/bridge_centroid_sf.rda"))
)

# Template plan for computing city pathways from source XML files
city_plan <- drake_plan(
  city_osm = read_big_osm(file_in("cities/city.xml"), way_keys = "highway"),
  city_base_graph = base_konigsberg_graph(city_osm),
  city_marked_graph = konigsberg_graph(city_base_graph, path_filter = automobile_highways, bridge_filter = main_bridges),
  city_pathway = cross_all_bridges(city_marked_graph, cheat = TRUE),
  city_visual = view_konigsberg_path(city_marked_graph, city_pathway)
)

# Take that template and replicate it, filling in the actual city name across all targets
route_plan <- dir_ls("cities") %>% 
  path_file() %>% 
  path_ext_remove() %>% 
  map_df(function(city_slug) {
    city_plan %>% 
      mutate(
        target = str_replace(target, "city", city_slug),
        command = str_replace_all(command, pattern = c("city" = city_slug)))
})

allpaths <- route_plan %>% 
  filter(str_detect(target, "pathway")) %>% 
  gather_plan(target = "all_paths")

venice_plan <- drake_plan(
  Venice_pedestrian_marked_graph = konigsberg_graph(Venice_base_graph, path_filter = pedestrian_highways, bridge_filter = all_bridges),
  Venice_pedestrian_pathway = cross_all_bridges(Venice_pedestrian_marked_graph, cheat = TRUE),
  Venice_pedestrian_visual = view_konigsberg_path(Venice_pedestrian_marked_graph, Venice_pedestrian_pathway)
)

path_analysis <- bind_plans(
  route_plan,
  venice_plan,
  allpaths,
  drake_plan(glanced_paths = map_df(all_paths, glance_path, .id = "city") %>% mutate(city = str_replace(city, "_pathway", "")))
)
