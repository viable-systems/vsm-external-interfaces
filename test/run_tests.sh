#!/bin/bash

# VSM Interfaces Test Runner
# Comprehensive test execution script with different test profiles

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test categories
UNIT_TESTS="test/unit/**/*_test.exs"
INTEGRATION_TESTS="test/integration/**/*_test.exs"
PERFORMANCE_TESTS="test/performance/**/*_test.exs"
PROPERTY_TESTS="test/property/**/*_test.exs"
E2E_TESTS="test/e2e/**/*_test.exs"

# Default values
RUN_ALL=false
RUN_UNIT=false
RUN_INTEGRATION=false
RUN_PERFORMANCE=false
RUN_PROPERTY=false
RUN_E2E=false
COVERAGE=false
VERBOSE=false
PROFILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            RUN_ALL=true
            shift
            ;;
        --unit)
            RUN_UNIT=true
            shift
            ;;
        --integration)
            RUN_INTEGRATION=true
            shift
            ;;
        --performance)
            RUN_PERFORMANCE=true
            shift
            ;;
        --property)
            RUN_PROPERTY=true
            shift
            ;;
        --e2e)
            RUN_E2E=true
            shift
            ;;
        --coverage)
            COVERAGE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --all           Run all test suites"
            echo "  --unit          Run unit tests only"
            echo "  --integration   Run integration tests only"
            echo "  --performance   Run performance tests only"
            echo "  --property      Run property-based tests only"
            echo "  --e2e           Run end-to-end tests only"
            echo "  --coverage      Generate coverage report"
            echo "  --verbose       Verbose test output"
            echo "  --profile NAME  Use specific test profile (ci, local, benchmark)"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# If no specific test suite selected, run unit and integration by default
if [ "$RUN_ALL" = false ] && [ "$RUN_UNIT" = false ] && [ "$RUN_INTEGRATION" = false ] && \
   [ "$RUN_PERFORMANCE" = false ] && [ "$RUN_PROPERTY" = false ] && [ "$RUN_E2E" = false ]; then
    RUN_UNIT=true
    RUN_INTEGRATION=true
fi

# Set environment based on profile
case $PROFILE in
    ci)
        export CI=true
        export MIX_ENV=test
        echo -e "${BLUE}Running in CI mode${NC}"
        ;;
    benchmark)
        export BENCHMARK=true
        export MIX_ENV=test
        echo -e "${BLUE}Running in benchmark mode${NC}"
        ;;
    local|"")
        export MIX_ENV=test
        echo -e "${BLUE}Running in local mode${NC}"
        ;;
    *)
        echo -e "${RED}Unknown profile: $PROFILE${NC}"
        exit 1
        ;;
esac

# Setup function
setup_test_env() {
    echo -e "${BLUE}Setting up test environment...${NC}"
    
    # Install dependencies
    mix deps.get --only test
    
    # Compile with test environment
    MIX_ENV=test mix compile --warnings-as-errors
    
    # Setup test database if needed
    # MIX_ENV=test mix ecto.create
    # MIX_ENV=test mix ecto.migrate
    
    # Start mock servers
    echo -e "${BLUE}Starting mock servers...${NC}"
    # Add commands to start mock HTTP, WebSocket, and gRPC servers
    
    echo -e "${GREEN}Test environment ready${NC}"
}

# Cleanup function
cleanup_test_env() {
    echo -e "${BLUE}Cleaning up test environment...${NC}"
    
    # Stop mock servers
    # Add commands to stop mock servers
    
    echo -e "${GREEN}Cleanup complete${NC}"
}

# Test execution function
run_tests() {
    local test_type=$1
    local test_pattern=$2
    local tag=$3
    
    echo -e "\n${BLUE}Running $test_type tests...${NC}"
    
    local cmd="mix test"
    
    if [ "$COVERAGE" = true ]; then
        cmd="mix coveralls.html"
    fi
    
    if [ "$VERBOSE" = true ]; then
        cmd="$cmd --trace"
    fi
    
    if [ -n "$tag" ]; then
        cmd="$cmd --include $tag"
    fi
    
    # Add test pattern
    cmd="$cmd $test_pattern"
    
    # Execute tests
    if $cmd; then
        echo -e "${GREEN}✓ $test_type tests passed${NC}"
        return 0
    else
        echo -e "${RED}✗ $test_type tests failed${NC}"
        return 1
    fi
}

# Main execution
main() {
    local exit_code=0
    
    # Setup
    setup_test_env
    
    # Trap to ensure cleanup runs
    trap cleanup_test_env EXIT
    
    # Run selected test suites
    if [ "$RUN_ALL" = true ] || [ "$RUN_UNIT" = true ]; then
        if ! run_tests "Unit" "$UNIT_TESTS" "unit"; then
            exit_code=1
        fi
    fi
    
    if [ "$RUN_ALL" = true ] || [ "$RUN_INTEGRATION" = true ]; then
        if ! run_tests "Integration" "$INTEGRATION_TESTS" "integration"; then
            exit_code=1
        fi
    fi
    
    if [ "$RUN_ALL" = true ] || [ "$RUN_PERFORMANCE" = true ]; then
        echo -e "\n${YELLOW}Warning: Performance tests may take a long time${NC}"
        if ! run_tests "Performance" "$PERFORMANCE_TESTS" "performance"; then
            exit_code=1
        fi
    fi
    
    if [ "$RUN_ALL" = true ] || [ "$RUN_PROPERTY" = true ]; then
        if ! run_tests "Property" "$PROPERTY_TESTS" "property"; then
            exit_code=1
        fi
    fi
    
    if [ "$RUN_ALL" = true ] || [ "$RUN_E2E" = true ]; then
        echo -e "\n${YELLOW}Warning: E2E tests require external services${NC}"
        if ! run_tests "End-to-End" "$E2E_TESTS" "e2e"; then
            exit_code=1
        fi
    fi
    
    # Generate coverage report
    if [ "$COVERAGE" = true ]; then
        echo -e "\n${BLUE}Coverage report generated at: cover/excoveralls.html${NC}"
    fi
    
    # Summary
    echo -e "\n${BLUE}Test Summary:${NC}"
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}All tests passed! 🎉${NC}"
    else
        echo -e "${RED}Some tests failed 😞${NC}"
    fi
    
    return $exit_code
}

# Run main function
main