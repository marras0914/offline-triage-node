-- Runs once, on first initialisation of an empty postgres_data volume.
--
-- Three separate databases on one server. n8n and NocoDB both keep internal
-- bookkeeping tables (n8n's include its encrypted credential store), and a
-- triage coordinator poking around a spreadsheet UI should never be one wrong
-- click away from either of them. Only `triage` holds field data.

CREATE DATABASE triage;
CREATE DATABASE nocodb_meta;
