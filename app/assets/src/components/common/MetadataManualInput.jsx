import React from "react";
import cx from "classnames";
import _fp, {
  zipObject,
  filter,
  keyBy,
  mapValues,
  set,
  union,
  get,
  values,
  includes,
  sortBy,
  find
} from "lodash/fp";

import MultipleDropdown from "~ui/controls/dropdowns/MultipleDropdown";
import DataTable from "~/components/visualizations/table/DataTable";
import PropTypes from "~/components/utils/propTypes";
import { Dropdown } from "~ui/controls/dropdowns";
import { getProjectMetadataFields, getAllHostGenomes } from "~/api";
import PlusIcon from "~ui/icons/PlusIcon";

import cs from "./metadata_manual_input.scss";
import MetadataInput from "./MetadataInput";

const map = _fp.map.convert({ cap: false });

class MetadataManualInput extends React.Component {
  state = {
    selectedFieldNames: [],
    projectMetadataFields: null,
    headers: null,
    metadataFieldsToEdit: {},
    headersToEdit: [],
    hostGenomes: []
  };

  async componentDidMount() {
    const [projectMetadataFields, hostGenomes] = await Promise.all([
      getProjectMetadataFields(this.props.project.id),
      getAllHostGenomes()
    ]);

    this.setState({
      projectMetadataFields: keyBy("key", projectMetadataFields),
      // Default to the required fields.
      selectedFieldNames: map(
        "key",
        filter(["is_required", 1], projectMetadataFields)
      ),
      hostGenomes,
      headers: {
        "Sample Name": "Sample Name",
        ...(this.props.samplesAreNew
          ? {
              "Host Genome": (
                <div>
                  Host Genome<span className={cs.requiredStar}>*</span>
                </div>
              )
            }
          : {}),
        ...mapValues(
          field =>
            this.props.samplesAreNew && field.is_required ? (
              <div>
                {field.name}
                <span className={cs.requiredStar}>*</span>
              </div>
            ) : (
              field.name
            ),
          keyBy("key", projectMetadataFields)
        )
      }
    });
  }

  getManualInputColumns = () => {
    return [
      "Sample Name",
      ...(this.props.samplesAreNew ? ["Host Genome"] : []),
      ...this.state.selectedFieldNames
    ];
  };

  handleHostGenomeChange = id => {
    this.setState({
      currentHostGenome: id
    });
  };

  // Update metadata field based on user's manual input.
  updateMetadataField = (key, value, sample) => {
    const newHeaders = union([key], this.state.headersToEdit);
    const newFields = set(
      [sample.name, key],
      value,
      this.state.metadataFieldsToEdit
    );
    this.setState({
      metadataFieldsToEdit: newFields,
      headersToEdit: newHeaders
    });

    this.props.onMetadataChange({
      metadata: {
        headers: ["sample_name", ...newHeaders],
        rows: map(
          (fields, sampleName) => ({
            ...mapValues(value => value || "", fields),
            sample_name: sampleName
          }),
          newFields
        )
      }
    });
  };

  getMetadataValue = (sample, key) => {
    // Return the manually edited value, or the original value fetched from the server.
    const editedValue = get(
      [sample.name, key],
      this.state.metadataFieldsToEdit
    );

    if (editedValue !== undefined) return editedValue;

    return get(key, sample.metadata);
  };

  handleColumnChange = selectedFieldNames => {
    this.setState({ selectedFieldNames });
  };

  getHostGenomeOptions = () =>
    sortBy(
      "text",
      this.state.hostGenomes.map(hostGenome => ({
        text: hostGenome.name,
        value: hostGenome.id
      }))
    );

  renderColumnSelector = () => {
    const { projectMetadataFields, selectedFieldNames } = this.state;

    const options = values(projectMetadataFields).map(field => ({
      value: field.key,
      text: field.name
    }));

    return (
      <MultipleDropdown
        direction="left"
        hideArrow
        hideCounter
        rounded
        search
        checkedOnTop
        menuLabel="Select Columns"
        onChange={this.handleColumnChange}
        options={options}
        trigger={<PlusIcon className={cs.plusIcon} />}
        value={selectedFieldNames}
        className={cs.columnPicker}
      />
    );
  };

  // Update host genome for a sample.
  updateHostGenome = (hostGenomeId, sample) => {
    this.updateMetadataField(
      "Host Genome",
      // Convert the id to a name.
      find(["id", hostGenomeId], this.state.hostGenomes).name,
      sample
    );
  };

  // Create form fields for the table.
  getManualInputData = () => {
    if (!this.props.samples) {
      return null;
    }
    return this.props.samples.map(sample => {
      const columns = this.getManualInputColumns();

      return zipObject(
        columns,
        // Render the table cell.
        columns.map(column => {
          if (column === "Sample Name") {
            return (
              <div className={cs.sampleName} key="Sample Name">
                {sample.name}
              </div>
            );
          }

          if (column === "Host Genome") {
            return (
              <Dropdown
                className={cs.input}
                options={this.getHostGenomeOptions()}
                value={this.state.currentHostGenome}
                onChange={id => this.updateHostGenome(id, sample)}
                usePortal
                withinModal={this.props.withinModal}
              />
            );
          }

          const sampleHostGenomeId = this.props.samplesAreNew
            ? get(
                "id",
                find(
                  ["name", this.getMetadataValue(sample, "Host Genome")],
                  this.state.hostGenomes
                )
              )
            : sample.host_genome_id;

          // Only show a MetadataInput if this metadata field matches the sample's host genome.
          if (
            includes(
              sampleHostGenomeId,
              this.state.projectMetadataFields[column].host_genome_ids
            )
          ) {
            return (
              <MetadataInput
                key={column}
                className={cs.input}
                value={this.getMetadataValue(sample, column)}
                metadataType={this.state.projectMetadataFields[column]}
                onChange={(key, value) =>
                  this.updateMetadataField(key, value, sample)
                }
                withinModal={this.props.withinModal}
              />
            );
          }
          return (
            <div className={cs.noInput} key={column}>
              {"--"}
            </div>
          );
        })
      );
    });
  };

  render() {
    if (!this.props.samples || !this.state.projectMetadataFields) {
      return <div className={cs.loadingMsg}>Loading...</div>;
    }

    return (
      <div className={cx(cs.metadataManualInput, this.props.className)}>
        {this.props.samplesAreNew && (
          <div className={cs.requiredMessage}>* = Required Field</div>
        )}
        <div className={cs.tableContainer}>
          <div className={cs.tableScrollWrapper}>
            <DataTable
              className={cs.inputTable}
              headers={this.state.headers}
              columns={this.getManualInputColumns()}
              data={this.getManualInputData()}
              getColumnWidth={column => (column === "Sample Name" ? 240 : 160)}
            />
          </div>
          {this.renderColumnSelector()}
        </div>
      </div>
    );
  }
}

MetadataManualInput.propTypes = {
  samples: PropTypes.arrayOf(PropTypes.Sample),
  project: PropTypes.Project,
  className: PropTypes.string,
  onMetadataChange: PropTypes.func.isRequired,
  samplesAreNew: PropTypes.bool,
  withinModal: PropTypes.bool
};

export default MetadataManualInput;