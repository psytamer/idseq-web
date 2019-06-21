import React from "react";
import PropTypes from "prop-types";
import { StickyContainer, Sticky } from "react-sticky";

import AMRHeatmapControls from "~/components/views/amr_heatmap/AMRHeatmapControls";
import AMRHeatmapVis from "~/components/views/amr_heatmap/AMRHeatmapVis";
import ErrorBoundary from "~/components/ErrorBoundary";
import { getAMRCounts } from "~/api/amr";
import LoadingIcon from "~ui/icons/LoadingIcon";
import { ViewHeader, NarrowContainer } from "~/components/layout";

import cs from "./amr_heatmap_view.scss";

const METRICS = [
  { text: "Coverage", value: "coverage" },
  { text: "Depth", value: "depth" },
];

const VIEW_LEVELS = [
  { text: "Genes", value: "gene" },
  { text: "Alleles", value: "allele" },
];

export default class AMRHeatmapView extends React.Component {
  constructor(props) {
    super(props);

    this.state = {
      loading: true,
      selectedOptions: {
        metric: "coverage",
        viewLevel: "gene",
      },
    };
  }

  componentDidMount() {
    this.requestAMRCountsData(this.props.sampleIds);
  }

  async requestAMRCountsData(sampleIds) {
    const rawSampleData = await getAMRCounts(sampleIds);
    const samplesWithAMRCounts = rawSampleData.filter(
      sampleData => sampleData.error === ""
    );
    this.setState({
      rawSampleData,
      samplesWithAMRCounts,
      sampleIds,
      loading: false,
    });
  }

  assembleControlOptions() {
    // Controls are arranged in the order they are presented in
    return [
      { key: "viewLevel", options: VIEW_LEVELS, label: "View Level" },
      { key: "metric", options: METRICS, label: "Metric" },
    ];
  }

  updateOptions = options => {
    let newOptions = Object.assign({}, this.state.selectedOptions, options);
    this.setState({
      selectedOptions: newOptions,
    });
  };

  renderVisualization() {
    if (this.state.loading) {
      return (
        <p className={cs.loadingIndicator}>
          <LoadingIcon className={cs.loadingIndicator} />
          Loading...
        </p>
      );
    }
    return (
      <div className="row visualization-content">
        <ErrorBoundary>
          <AMRHeatmapVis
            samplesWithAMRCounts={this.state.samplesWithAMRCounts}
            selectedOptions={this.state.selectedOptions}
          />
        </ErrorBoundary>
      </div>
    );
  }

  render() {
    return (
      <div className={cs.AMRHeatmapView}>
        <NarrowContainer>
          <ViewHeader className={cs.viewHeader}>
            <ViewHeader.Content>
              <ViewHeader.Pretitle>
                Antimicrobial Resistance Heatmap
              </ViewHeader.Pretitle>
              <ViewHeader.Title
                label={`Comparing ${
                  this.props.sampleIds ? this.props.sampleIds.length : ""
                } Samples`}
              />
            </ViewHeader.Content>
          </ViewHeader>
        </NarrowContainer>
        <StickyContainer>
          <Sticky>
            {({ style }) => (
              <div style={style}>
                <NarrowContainer>
                  <AMRHeatmapControls
                    controls={this.assembleControlOptions()}
                    selectedOptions={this.state.selectedOptions}
                    onSelectedOptionsChange={this.updateOptions}
                    isDataReady={!this.state.loading}
                  />
                </NarrowContainer>
              </div>
            )}
          </Sticky>
          {this.renderVisualization()}
        </StickyContainer>
      </div>
    );
  }
}

AMRHeatmapVis.propTypes = {
  sampleIds: PropTypes.array,
};