#include "text_utils.hpp"

#include <algorithm>
#include <sstream>

namespace nshtest {

std::vector<std::string> split_lines(const std::string &text)
{
    std::vector<std::string> lines;
    std::istringstream stream(text);
    std::string line;

    while (std::getline(stream, line))
        lines.push_back(line);

    return lines;
}

std::vector<std::string> sorted_lines(const std::string &text)
{
    std::vector<std::string> lines = split_lines(text);
    std::sort(lines.begin(), lines.end());
    return lines;
}

std::string join_lines(const std::vector<std::string> &lines)
{
    std::string out;

    for (size_t i = 0; i < lines.size(); i++) {
        if (i > 0)
            out += '\n';
        out += lines[i];
    }

    return out;
}

} // namespace nshtest
