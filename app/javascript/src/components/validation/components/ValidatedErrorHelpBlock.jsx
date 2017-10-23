import React, { Component } from "react";
import { HelpBlock } from "react-bootstrap";
import { FormattedMessage } from "react-intl";
import PropTypes from "prop-types";
import styled from "styled-components";
import shortid from "shortid";

const MyHelpBlock = styled(HelpBlock)`
  & > span {
    margin-right: 5px;
  }
`;

class ValidatedErrorHelpBlock extends Component {
  static renderErrorMessage(error) {
    const key = shortid.generate();
    if (error.intl) {
      return (
        <FormattedMessage
          key={key}
          id={error.messageId}
          values={error.values}
        />
      );
    }
    return <span key={key}>{error.message}</span>;
  }

  constructor(props) {
    super(props);

    this.cleanProps = this.cleanProps.bind(this);
  }

  cleanProps() {
    // Remove additional props from the props
    const { tag, ...cleanProps } = this.props;
    return cleanProps;
  }

  render() {
    const errors = this.context.errors(this.props.tag) || [];
    return (
      <MyHelpBlock {...this.cleanProps()}>
        {errors.map((error) => ValidatedErrorHelpBlock.renderErrorMessage(error))}
      </MyHelpBlock>
    );
  }
}

ValidatedErrorHelpBlock.propTypes = {
  tag: PropTypes.string.isRequired
};

ValidatedErrorHelpBlock.contextTypes = {
  errors: PropTypes.func
}

export default ValidatedErrorHelpBlock;